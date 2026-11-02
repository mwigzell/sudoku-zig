package com.wigzell.sudoku_zig.test;

// File bridge scenarios on a real device: drive the installed app's UI, check MediaStore and the app's files.
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import android.app.UiAutomation;
import android.graphics.Rect;
import android.os.ParcelFileDescriptor;
import android.os.SystemClock;
import android.util.Xml;

import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.uiautomator.By;
import androidx.test.uiautomator.BySelector;
import androidx.test.uiautomator.UiDevice;
import androidx.test.uiautomator.UiObject2;
import androidx.test.uiautomator.Until;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.StringReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.junit.Before;
import org.junit.Test;
import org.xmlpull.v1.XmlPullParser;
import org.xmlpull.v1.XmlPullParserException;

public final class FileBridgeTest {
    private static final String APP = "com.wigzell.sudoku_zig";
    private static final String SAVE_DIR = "/sdcard/Download/Sudoku";
    private static final String SAVE_RELATIVE_PATH = "Download/Sudoku/";
    private static final String DEFAULT_NAME = "sudoku.sud";
    private static final Pattern DEFAULT_OR_RENAMED = Pattern.compile("sudoku( \\(\\d+\\))?\\.sud");
    private static final String AUTO_SAVE_SETTINGS =
        "{\"difficulty\":\"easy\",\"log_level\":\"info\",\"theme\":\"system\",\"show_region\":false,"
            + "\"warn_solvability\":false,\"auto_restore\":false,\"auto_new\":false,\"auto_save\":true}";
    private static final Pattern MEDIA_ROW =
        Pattern.compile("_id=(\\d+), _display_name=(.*), owner_package_name=(.*)$");
    private static final Pattern BOUND_NAME = Pattern.compile("name=\"current_name\">([^<]*)<");
    private static final Pattern BOUNDS = Pattern.compile("\\[(\\d+),(\\d+)\\]\\[(\\d+),(\\d+)\\]");
    private static final String COLUMN_LABELS = "ABCDEFGHI";
    private static final String FILL_DIGIT = "5";
    private static final long UI_WAIT_MS = 20_000;
    private static final long GENERATE_WAIT_MS = 180_000;
    private static final long POLL_MS = 250;

    private UiDevice device;
    /** Cells this test filled; a clashing digit is not reported in the accessibility text, so track them here. */
    private final Set<String> tappedCells = new HashSet<>();

    /** One MediaStore row in the visible save folder. */
    private static final class MediaEntry {
        final long id;
        final String name;
        final String owner;

        MediaEntry(long id, String name, String owner) {
            this.id = id;
            this.name = name;
            this.owner = owner;
        }

        @Override
        public String toString() {
            return name + " (id " + id + ", owner " + owner + ")";
        }
    }

    /** One node of a `dumpWindowHierarchy` snapshot. */
    private static final class SnapshotNode {
        final String resourceId;
        final String className;
        final String text;
        final Rect bounds;

        SnapshotNode(String resourceId, String className, String text, Rect bounds) {
            this.resourceId = resourceId;
            this.className = className;
            this.text = text;
            this.bounds = bounds;
        }

        static List<SnapshotNode> parse(String xml) throws IOException {
            final List<SnapshotNode> nodes = new ArrayList<>();
            try {
                final XmlPullParser parser = Xml.newPullParser();
                parser.setInput(new StringReader(xml));
                for (int ev = parser.getEventType(); ev != XmlPullParser.END_DOCUMENT; ev = parser.next()) {
                    if (ev != XmlPullParser.START_TAG || !"node".equals(parser.getName())) continue;
                    final Matcher b = BOUNDS.matcher(attr(parser, "bounds"));
                    if (!b.matches()) continue;
                    nodes.add(new SnapshotNode(
                        attr(parser, "resource-id"),
                        attr(parser, "class"),
                        attr(parser, "text"),
                        new Rect(Integer.parseInt(b.group(1)), Integer.parseInt(b.group(2)), Integer.parseInt(b.group(3)), Integer.parseInt(b.group(4)))));
                }
            } catch (XmlPullParserException err) {
                throw new IOException("unreadable window hierarchy", err);
            }
            return nodes;
        }

        private static String attr(XmlPullParser parser, String name) {
            final String value = parser.getAttributeValue(null, name);
            return value == null ? "" : value;
        }
    }

    /** A cleared app with Auto Save on, and no default save file (or renamed copy) in the save folder. */
    @Before
    public void freshAppWithAutoSave() throws IOException {
        device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation());
        sh("am force-stop " + APP + "\n"
            + "pm clear " + APP + "\n"
            + "rm -f " + SAVE_DIR + "/" + DEFAULT_NAME + " " + SAVE_DIR + "/sudoku\\ \\(*\\).sud\n"
            + "run-as " + APP + " mkdir -p files\n"
            + "echo '" + AUTO_SAVE_SETTINGS + "' | run-as " + APP + " sh -c 'cat > files/settings.json'\n");
    }

    @Test
    public void firstAutosaveCreatesAndBindsTheDefaultFileThenRewritesTheSameEntry() throws IOException {
        launchApp();
        startEasyGame();

        fillAnEmptyCell();
        final MediaEntry created = awaitDefaultEntry();
        assertEquals(APP, created.owner);
        assertEquals(DEFAULT_NAME, awaitBoundName());
        final String firstHash = saveFileHash();

        fillAnEmptyCell();
        awaitSaveFileHashOtherThan(firstHash);
        final List<MediaEntry> after = defaultOrRenamedEntries();
        assertEquals("one save entry after the rewrite: " + after, 1, after.size());
        assertEquals("the rewrite reuses the entry", created.id, after.get(0).id);
    }

    private void launchApp() throws IOException {
        sh("am start -W -n " + APP + "/.MainActivity\n");
        need(By.res("board"), UI_WAIT_MS);
        need(By.text("File"), UI_WAIT_MS);
    }

    private void startEasyGame() {
        need(By.text("File"), UI_WAIT_MS).click();
        need(By.res("file-new"), UI_WAIT_MS).click();
        need(By.text("Easy").clickable(true), UI_WAIT_MS).click();
        need(By.res("generating-modal-continue").enabled(true), GENERATE_WAIT_MS).click();
        device.wait(Until.gone(By.res("generating-modal-continue")), UI_WAIT_MS);
    }

    /** Tap the first empty cell not yet tapped (found from the row and column labels) and enter a digit on the play pad. */
    private void fillAnEmptyCell() throws IOException {
        final int[] cell = firstEmptyCellCenter();
        tappedCells.add(cell[0] + "," + cell[1]);
        device.click(cell[0], cell[1]);
        need(By.res("play-pad"), UI_WAIT_MS).findObject(By.text(FILL_DIGIT)).click();
    }

    /** Read one hierarchy snapshot (live WebView nodes are replaced while the board redraws); a snapshot taken mid-rebuild may lack the board, so take another. */
    private int[] firstEmptyCellCenter() throws IOException {
        final long deadline = SystemClock.uptimeMillis() + UI_WAIT_MS;
        List<SnapshotNode> nodes;
        Rect board;
        do {
            device.waitForIdle();
            final ByteArrayOutputStream xml = new ByteArrayOutputStream();
            device.dumpWindowHierarchy(xml);
            nodes = SnapshotNode.parse(xml.toString(StandardCharsets.UTF_8.name()));
            board = null;
            for (SnapshotNode n : nodes) {
                if ("board".equals(n.resourceId)) board = n.bounds;
            }
            if (board == null) SystemClock.sleep(POLL_MS);
        } while (board == null && SystemClock.uptimeMillis() < deadline);
        assertNotNull("the board is not shown", board);
        final int[] columnX = new int[COLUMN_LABELS.length()];
        final int[] rowY = new int[COLUMN_LABELS.length()];
        final List<Rect> filled = new ArrayList<>();
        for (SnapshotNode n : nodes) {
            if (!board.contains(n.bounds) || n.text.length() != 1) continue;
            final char c = n.text.charAt(0);
            if (n.className.endsWith("TextView")) {
                if (c >= 'A' && c <= 'I') columnX[c - 'A'] = n.bounds.centerX();
                if (c >= '1' && c <= '9') rowY[c - '1'] = n.bounds.centerY();
            } else if (c >= '1' && c <= '9') {
                filled.add(n.bounds);
            }
        }
        for (int y : rowY) {
            for (int x : columnX) {
                if (x == 0 || y == 0) fail("board labels are not all shown");
                if (!containsPoint(filled, x, y) && !tappedCells.contains(x + "," + y)) return new int[] { x, y };
            }
        }
        fail("the board has no empty cell");
        return null;
    }

    private static boolean containsPoint(List<Rect> rects, int x, int y) {
        for (Rect r : rects) {
            if (r.contains(x, y)) return true;
        }
        return false;
    }

    private UiObject2 need(BySelector selector, long timeoutMs) {
        final UiObject2 found = device.wait(Until.findObject(selector), timeoutMs);
        assertNotNull("not shown within " + timeoutMs + " ms: " + selector, found);
        return found;
    }

    private MediaEntry awaitDefaultEntry() throws IOException {
        final long deadline = SystemClock.uptimeMillis() + UI_WAIT_MS;
        List<MediaEntry> entries = defaultOrRenamedEntries();
        while (entries.isEmpty() && SystemClock.uptimeMillis() < deadline) {
            SystemClock.sleep(POLL_MS);
            entries = defaultOrRenamedEntries();
        }
        assertEquals("exactly the default save entry: " + entries, 1, entries.size());
        assertEquals(DEFAULT_NAME, entries.get(0).name);
        return entries.get(0);
    }

    private List<MediaEntry> defaultOrRenamedEntries() throws IOException {
        final String out = sh("content query --uri content://media/external/downloads"
            + " --projection _id:_display_name:owner_package_name"
            + " --where \"relative_path='" + SAVE_RELATIVE_PATH + "'\"\n");
        final List<MediaEntry> entries = new ArrayList<>();
        for (String line : out.split("\n")) {
            final Matcher m = MEDIA_ROW.matcher(line.trim());
            if (!m.find()) continue;
            if (!DEFAULT_OR_RENAMED.matcher(m.group(2)).matches()) continue;
            entries.add(new MediaEntry(Long.parseLong(m.group(1)), m.group(2), m.group(3)));
        }
        return entries;
    }

    private String awaitBoundName() throws IOException {
        final long deadline = SystemClock.uptimeMillis() + UI_WAIT_MS;
        while (true) {
            final Matcher m = BOUND_NAME.matcher(sh("run-as " + APP + " cat shared_prefs/sudoku_file_binding.xml\n"));
            if (m.find()) return m.group(1);
            if (SystemClock.uptimeMillis() > deadline) fail("the app bound no file");
            SystemClock.sleep(POLL_MS);
        }
    }

    private String saveFileHash() throws IOException {
        final String out = sh("md5sum " + SAVE_DIR + "/" + DEFAULT_NAME + "\n").trim();
        assertTrue("cannot read " + DEFAULT_NAME + ": " + out, out.matches("[0-9a-f]{32} .*"));
        return out.substring(0, 32);
    }

    private void awaitSaveFileHashOtherThan(String previous) throws IOException {
        final long deadline = SystemClock.uptimeMillis() + UI_WAIT_MS;
        while (saveFileHash().equals(previous)) {
            if (SystemClock.uptimeMillis() > deadline) fail(DEFAULT_NAME + " was not rewritten after the move");
            SystemClock.sleep(POLL_MS);
        }
    }

    /** Run a script in the device shell (stdin-fed, so quoting and pipes work) and return its output. */
    private static String sh(String script) throws IOException {
        final UiAutomation automation = InstrumentationRegistry.getInstrumentation().getUiAutomation();
        final ParcelFileDescriptor[] fds = automation.executeShellCommandRw("sh");
        try (OutputStream in = new ParcelFileDescriptor.AutoCloseOutputStream(fds[1])) {
            in.write(script.getBytes(StandardCharsets.UTF_8));
        }
        try (InputStream out = new ParcelFileDescriptor.AutoCloseInputStream(fds[0])) {
            final ByteArrayOutputStream buf = new ByteArrayOutputStream();
            final byte[] chunk = new byte[4096];
            for (int n; (n = out.read(chunk)) != -1; ) buf.write(chunk, 0, n);
            return buf.toString(StandardCharsets.UTF_8.name());
        }
    }
}
