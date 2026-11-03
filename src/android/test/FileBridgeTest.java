package com.wigzell.sudoku_zig.test;

// File bridge scenarios on a real device: drive the installed app's UI and the system pickers, check MediaStore and the app's files.
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import android.app.UiAutomation;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Rect;
import android.os.ParcelFileDescriptor;
import android.os.SystemClock;
import android.util.Base64;
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

import org.junit.After;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TestWatcher;
import org.junit.runner.Description;
import org.xmlpull.v1.XmlPullParser;
import org.xmlpull.v1.XmlPullParserException;

public final class FileBridgeTest {
    private static final String APP = "com.wigzell.sudoku_zig";
    /** Pushed by the host script so a test can reinstall the app. */
    private static final String APP_APK_ON_DEVICE = "/data/local/tmp/sudoku-app.apk";
    /** Screenshots and window hierarchies of failed tests; the host script pulls them. */
    private static final String FAILURE_DIR = "/data/local/tmp/sudoku-test-failure";
    private static final String OTHER_FOLDER = "/storage/emulated/0/Download";
    private static final String SAVE_FOLDER_NAME = "Sudoku";
    private static final String SAVE_DIR = "/sdcard/Download/" + SAVE_FOLDER_NAME;
    private static final String BINDING_PREFS = "shared_prefs/sudoku_file_binding.xml";
    private static final String SAVE_RELATIVE_PATH = "Download/Sudoku/";
    private static final String DEFAULT_NAME = "sudoku.sud";
    private static final String DEFAULT_PATH = SAVE_DIR + "/" + DEFAULT_NAME;
    private static final Pattern DEFAULT_OR_RENAMED = Pattern.compile("sudoku( \\(\\d+\\))?\\.sud");
    /** Name typed into the create picker; the picker may add " (1)" if its folder already has one. */
    private static final String CHOSEN_NAME = "bridge-test.sud";
    private static final String CHOSEN_NAME_LIKE = "bridge-test%.sud";
    /** Auto Save on; `%b` is Auto Restore. */
    private static final String AUTO_SAVE_SETTINGS_FMT =
        "{\"difficulty\":\"easy\",\"log_level\":\"info\",\"theme\":\"system\",\"show_region\":false,"
            + "\"warn_solvability\":false,\"auto_restore\":%b,\"auto_new\":false,\"auto_save\":true}";
    /** Light theme, nothing to restore. */
    private static final String LIGHT_THEME_SETTINGS =
        "{\"difficulty\":\"easy\",\"log_level\":\"info\",\"theme\":\"light\",\"show_region\":false,"
            + "\"warn_solvability\":false,\"auto_restore\":false,\"auto_new\":false,\"auto_save\":false}";
    /** Launch frames are sampled for this long; the splash shows for a minimum time, then fades. */
    private static final long LAUNCH_WATCH_MS = 6_000;
    private static final int DARK_RGB_SUM = 120;
    private static final int LIGHT_RGB_SUM = 600;
    private static final Pattern MEDIA_ROW =
        Pattern.compile("_id=(\\d+), _display_name=(.*), owner_package_name=(.*)$");
    private static final Pattern MEDIA_PATH = Pattern.compile("_data=(.*)$");
    private static final Pattern BOUND_NAME = Pattern.compile("name=\"current_name\">([^<]*)<");
    /** The host's log line for a write of the hidden restore copy. */
    private static final Pattern RESTORE_COPY_WRITE = Pattern.compile("current-file write: .*restore_copy=true");
    private static final Pattern BOUNDS = Pattern.compile("\\[(\\d+),(\\d+)\\]\\[(\\d+),(\\d+)\\]");
    private static final String COLUMN_LABELS = "ABCDEFGHI";
    private static final String FILL_DIGIT = "5";
    // Page ids: the ask dialog (core's question with its two answers) and the file label in the menu bar.
    private static final String ASK_TEXT = "replace-confirm-msg";
    private static final String ASK_OK = "replace-confirm-ok";
    private static final String ASK_CANCEL = "replace-confirm-cancel";
    private static final String FILE_LABEL = "current-file-desktop";
    // DocumentsUI views: a listed file's name, the create picker's name field, and its Save button.
    private static final String PICKER_ITEM_NAME = "android:id/title";
    private static final String PICKER_NAME_FIELD = "android:id/title";
    private static final String PICKER_SAVE = "android:id/button1";
    private static final int PICKER_BACK_LIMIT = 5;
    private static final long UI_WAIT_MS = 20_000;
    private static final long GENERATE_WAIT_MS = 180_000;
    private static final long POLL_MS = 250;

    private UiDevice device;
    /** Cells this test filled; a clashing digit is not reported in the accessibility text, so track them here. */
    private final Set<String> tappedCells = new HashSet<>();

    @Rule
    public final TestWatcher keepFailureScreen = new TestWatcher() {
        @Override
        protected void failed(Throwable e, Description description) {
            try {
                final String base = FAILURE_DIR + "/" + description.getMethodName();
                final ByteArrayOutputStream xml = new ByteArrayOutputStream();
                device.dumpWindowHierarchy(xml);
                sh("mkdir -p " + FAILURE_DIR + "\n"
                    + "screencap -p " + base + ".png\n"
                    + "base64 -d > " + base + ".xml <<'EOF'\n"
                    + Base64.encodeToString(xml.toByteArray(), Base64.DEFAULT)
                    + "EOF\n");
            } catch (IOException | RuntimeException ignored) {
                // The failure itself is what the run reports.
            }
        }
    };

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

    /** A cleared app with Auto Save on, and no default save file, renamed copy or chosen-name file. */
    @Before
    public void freshAppWithAutoSave() throws IOException {
        device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation());
        sh("am force-stop " + APP + "\n"
            + "pm clear " + APP + "\n"
            + "rm -f " + DEFAULT_PATH + " " + SAVE_DIR + "/sudoku\\ \\(*\\).sud\n");
        deleteChosenNameFiles();
        writeAutoSaveSettings(false);
    }

    @After
    public void removeChosenNameFiles() throws IOException {
        deleteChosenNameFiles();
    }

    @Test
    public void systemBarsStayDarkUntilTheSplashIsGoneThenTakeTheTheme() throws IOException {
        writeSettings(LIGHT_THEME_SETTINGS);
        sh("am start -n " + APP + "/.MainActivity\n");
        final UiAutomation automation = InstrumentationRegistry.getInstrumentation().getUiAutomation();
        final long started = SystemClock.uptimeMillis();
        final long deadline = started + LAUNCH_WATCH_MS;
        boolean sawSplash = false;
        boolean barsLightAtEnd = false;
        while (SystemClock.uptimeMillis() < deadline) {
            if (!APP.equals(device.getCurrentPackageName())) continue;
            final Bitmap frame = automation.takeScreenshot();
            if (frame == null) continue;
            final int bar = rgbSum(frame.getPixel(frame.getWidth() / 2, 10));
            final int middle = rgbSum(frame.getPixel(20, frame.getHeight() / 2));
            final boolean splash = middle < DARK_RGB_SUM;
            frame.recycle();
            if (splash) {
                sawSplash = true;
                assertFalse(
                    "the system bars took the light theme while the splash was showing (bar " + bar
                        + ", middle " + middle + ", " + (SystemClock.uptimeMillis() - started) + " ms after launch)",
                    bar > LIGHT_RGB_SUM);
            }
            barsLightAtEnd = !splash && bar > LIGHT_RGB_SUM;
        }
        assertTrue("the splash was never seen", sawSplash);
        assertTrue("the system bars did not take the light theme after the splash", barsLightAtEnd);
    }

    @Test
    public void firstAutosaveCreatesAndBindsTheDefaultFileThenRewritesTheSameEntry() throws IOException {
        launchApp();
        startEasyGame();

        fillAnEmptyCell();
        final MediaEntry created = awaitDefaultEntry();
        assertEquals(APP, created.owner);
        assertEquals(DEFAULT_NAME, awaitBoundName());
        assertEquals(DEFAULT_NAME, awaitFileLabel(DEFAULT_NAME));
        final String firstHash = fileHash(DEFAULT_PATH);

        fillAnEmptyCell();
        awaitFileHashOtherThan(DEFAULT_PATH, firstHash);
        final List<MediaEntry> after = defaultOrRenamedEntries();
        assertEquals("one save entry after the rewrite: " + after, 1, after.size());
        assertEquals("the rewrite reuses the entry", created.id, after.get(0).id);
    }

    @Test
    public void autosaveAfterAnotherNewGameRewritesTheBoundFile() throws IOException {
        launchApp();
        startEasyGame();
        fillAnEmptyCell();
        final MediaEntry created = awaitDefaultEntry();
        awaitBoundName();
        final String firstGameHash = fileHash(DEFAULT_PATH);

        startEasyGame();
        fillAnEmptyCell();
        replaceWhenAsked(DEFAULT_NAME);
        awaitFileHashOtherThan(DEFAULT_PATH, firstGameHash);
        final List<MediaEntry> after = defaultOrRenamedEntries();
        assertEquals("one save entry after the new game: " + after, 1, after.size());
        assertEquals("the new game is written to the same entry", created.id, after.get(0).id);
        assertEquals(DEFAULT_NAME, awaitFileLabel(DEFAULT_NAME));
    }

    @Test
    public void reinstallWithTheDefaultFileLeftAsksInsteadOfWritingARenamedCopy() throws IOException {
        final String earlierHash = reachTakenAskAfterReinstall();

        final String question = need(By.res(ASK_TEXT), UI_WAIT_MS).getText();
        assertTrue("the question names the file: " + question, question.contains(DEFAULT_NAME));
        final List<MediaEntry> entries = defaultOrRenamedEntries();
        assertEquals("only the earlier install's file: " + entries, 1, entries.size());
        assertEquals(DEFAULT_NAME, entries.get(0).name);
        assertEquals("no renamed copy on disk", DEFAULT_PATH + "\n", sh("ls " + SAVE_DIR + "/*.sud\n"));
        assertEquals("the earlier file is untouched", earlierHash, fileHash(DEFAULT_PATH));
        assertEquals("nothing is bound before the user answers", "", boundNameNow());
    }

    @Test
    public void pickItWritesTheEarlierFileBindsItAndKeepsAutosavingThere() throws IOException {
        final String earlierHash = reachTakenAskAfterReinstall();

        need(By.res(ASK_OK), UI_WAIT_MS).click();
        need(By.res(PICKER_ITEM_NAME).text(DEFAULT_NAME), UI_WAIT_MS).click();
        final String pickedHash = awaitFileHashOtherThan(DEFAULT_PATH, earlierHash);
        assertEquals(DEFAULT_NAME, awaitBoundName());
        assertEquals(DEFAULT_NAME, awaitFileLabel(DEFAULT_NAME));

        fillAnEmptyCell();
        awaitFileHashOtherThan(DEFAULT_PATH, pickedHash);
        assertEquals("no renamed copy: " + defaultOrRenamedEntries(), 1, defaultOrRenamedEntries().size());
    }

    @Test
    public void newNameWritesTheChosenFileBindsItAndLeavesTheEarlierFile() throws IOException {
        final String earlierHash = reachTakenAskAfterReinstall();

        need(By.res(ASK_CANCEL), UI_WAIT_MS).click();
        saveInCreatePicker(CHOSEN_NAME);
        final String chosenPath = awaitChosenNamePath();
        final String chosenName = chosenPath.substring(chosenPath.lastIndexOf('/') + 1);
        assertEquals(chosenName, awaitBoundName());
        assertEquals(chosenName, awaitFileLabel(chosenName));
        final String chosenHash = fileHash(chosenPath);

        fillAnEmptyCell();
        awaitFileHashOtherThan(chosenPath, chosenHash);
        assertEquals("the earlier file is untouched", earlierHash, fileHash(DEFAULT_PATH));
    }

    @Test
    public void backingOutOfEitherPickerAsksAgain() throws IOException {
        reachTakenAskAfterReinstall();
        final String question = need(By.res(ASK_TEXT), UI_WAIT_MS).getText();

        need(By.res(ASK_OK), UI_WAIT_MS).click();
        need(By.res(PICKER_ITEM_NAME).text(DEFAULT_NAME), UI_WAIT_MS);
        backOutOfPicker();
        assertEquals("asked again after backing out of Pick it", question, need(By.res(ASK_TEXT), UI_WAIT_MS).getText());

        need(By.res(ASK_CANCEL), UI_WAIT_MS).click();
        need(By.res(PICKER_SAVE), UI_WAIT_MS);
        backOutOfPicker();
        assertEquals("asked again after backing out of New name", question, need(By.res(ASK_TEXT), UI_WAIT_MS).getText());
        assertEquals("nothing is bound", "", boundNameNow());
    }

    @Test
    public void bindingSurvivesAnAppRestart() throws IOException {
        launchApp();
        startEasyGame();
        need(By.text("File"), UI_WAIT_MS).click();
        need(By.res("file-save-as"), UI_WAIT_MS).click();
        saveInCreatePicker(CHOSEN_NAME);
        final String chosenPath = awaitChosenNamePath();
        final String chosenName = chosenPath.substring(chosenPath.lastIndexOf('/') + 1);
        assertEquals(chosenName, awaitBoundName());
        final String savedHash = fileHash(chosenPath);

        sh("am force-stop " + APP + "\n");
        launchApp();
        startEasyGame();
        fillAnEmptyCell();
        replaceWhenAsked(chosenName);
        awaitFileHashOtherThan(chosenPath, savedHash);
        assertEquals(chosenName, awaitFileLabel(chosenName));
        assertEquals("no default file after the restart: " + defaultOrRenamedEntries(), 0, defaultOrRenamedEntries().size());
    }

    @Test
    public void autoRestoreReopensTheBoundFileAndTheNextMoveWritesIt() throws IOException {
        writeAutoSaveSettings(true);
        launchApp();
        startEasyGame();
        need(By.text("File"), UI_WAIT_MS).click();
        need(By.res("file-save-as"), UI_WAIT_MS).click();
        saveInCreatePicker(CHOSEN_NAME);
        final String chosenPath = awaitChosenNamePath();
        final String chosenName = chosenPath.substring(chosenPath.lastIndexOf('/') + 1);
        assertEquals(chosenName, awaitBoundName());
        final String savedHash = fileHash(chosenPath);

        sh("am force-stop " + APP + "\n");
        launchApp();
        assertEquals("the restored game is labelled with its file", chosenName, awaitFileLabel(chosenName));
        tappedCells.clear();
        fillAnEmptyCell();
        awaitFileHashOtherThan(chosenPath, savedHash);
        assertFalse("a restored game continues its file without asking", device.hasObject(By.res(ASK_TEXT)));
        assertEquals("no default file after the restart: " + defaultOrRenamedEntries(), 0, defaultOrRenamedEntries().size());
    }

    @Test
    public void withNoBoundFileSaveAsStartsInTheDefaultFolderNotWhereThePickerWasLast() throws IOException {
        sh("mkdir -p " + SAVE_DIR + " && echo earlier > " + DEFAULT_PATH + "\n");
        launchApp();
        startEasyGame();
        need(By.text("File"), UI_WAIT_MS).click();
        need(By.res("file-save-as"), UI_WAIT_MS).click();
        need(By.res(PICKER_ITEM_NAME).text(DEFAULT_NAME), UI_WAIT_MS);
        device.pressBack();
        need(By.res(PICKER_ITEM_NAME).text(SAVE_FOLDER_NAME), UI_WAIT_MS);
        saveInCreatePicker(CHOSEN_NAME);
        final String chosenPath = awaitChosenNamePath();
        assertEquals("saved in the folder above the default folder", OTHER_FOLDER + "/" + CHOSEN_NAME, chosenPath);

        sh("am force-stop " + APP + "\n" + "run-as " + APP + " rm -f " + BINDING_PREFS + "\n");
        launchApp();
        startEasyGame();
        need(By.text("File"), UI_WAIT_MS).click();
        need(By.res("file-save-as"), UI_WAIT_MS).click();
        need(By.res(PICKER_ITEM_NAME).text(DEFAULT_NAME), UI_WAIT_MS);
        assertFalse("the picker is in the default folder, not the folder above it",
            device.hasObject(By.res(PICKER_ITEM_NAME).text(SAVE_FOLDER_NAME)));
        backOutOfPicker();
    }

    @Test
    public void closingTheAppFlushesTheRestoreCopy() throws IOException {
        launchApp();
        startEasyGame();
        sh("logcat -c\n");
        fillAnEmptyCell();
        awaitLog(RESTORE_COPY_WRITE);

        sh("logcat -c\n");
        device.pressHome();
        awaitLog(RESTORE_COPY_WRITE);
    }

    /** A new game's first autosave over an existing file asks first; answer Replace. */
    private void replaceWhenAsked(String name) {
        final String question = need(By.res(ASK_TEXT), UI_WAIT_MS).getText();
        assertTrue("the replace question names " + name + ": " + question, question.contains(name));
        need(By.res(ASK_OK), UI_WAIT_MS).click();
    }

    /** DocumentsUI's Back first walks up the folder tree; press it until the app is in front again. */
    private void backOutOfPicker() {
        for (int i = 0; i < PICKER_BACK_LIMIT && !APP.equals(device.getCurrentPackageName()); i++) {
            device.pressBack();
            device.waitForIdle();
        }
        assertEquals("the picker closed", APP, device.getCurrentPackageName());
    }

    /**
     * Play until the default file exists, reinstall the app (the file stays, owned by the earlier install), then play
     * again until the app asks what to do. Returns the earlier file's hash.
     */
    private String reachTakenAskAfterReinstall() throws IOException {
        launchApp();
        startEasyGame();
        fillAnEmptyCell();
        awaitDefaultEntry();
        final String earlierHash = fileHash(DEFAULT_PATH);

        final String reinstalled = sh("pm uninstall " + APP + "\n" + "pm install -t " + APP_APK_ON_DEVICE + "\n");
        assertTrue("reinstall: " + reinstalled, reinstalled.trim().endsWith("Success"));
        writeAutoSaveSettings(false);
        tappedCells.clear();

        launchApp();
        startEasyGame();
        fillAnEmptyCell();
        need(By.res(ASK_OK), UI_WAIT_MS);
        return earlierHash;
    }

    private static int rgbSum(int color) {
        return Color.red(color) + Color.green(color) + Color.blue(color);
    }

    private void writeAutoSaveSettings(boolean autoRestore) throws IOException {
        writeSettings(String.format(AUTO_SAVE_SETTINGS_FMT, autoRestore));
    }

    private void writeSettings(String settings) throws IOException {
        sh("run-as " + APP + " mkdir -p files\n"
            + "echo '" + settings + "' | run-as " + APP + " sh -c 'cat > files/settings.json'\n");
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
        tappedCells.clear();
    }

    /** In DocumentsUI's create picker (whichever folder it opens in), type `name` and save. */
    private void saveInCreatePicker(String name) {
        need(By.res(PICKER_SAVE), UI_WAIT_MS);
        need(By.res(PICKER_NAME_FIELD).clazz("android.widget.EditText"), UI_WAIT_MS).setText(name);
        need(By.res(PICKER_SAVE), UI_WAIT_MS).click();
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

    private String awaitFileLabel(String expected) {
        device.wait(Until.hasObject(By.res(FILE_LABEL).text(expected)), UI_WAIT_MS);
        return need(By.res(FILE_LABEL), UI_WAIT_MS).getText();
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

    /** Paths of files the create picker saved under the chosen name, wherever its folder was. */
    private List<String> chosenNamePaths() throws IOException {
        final String out = sh("content query --uri content://media/external/file --projection _data"
            + " --where \"_display_name LIKE '" + CHOSEN_NAME_LIKE + "'\"\n");
        final List<String> paths = new ArrayList<>();
        for (String line : out.split("\n")) {
            final Matcher m = MEDIA_PATH.matcher(line.trim());
            if (m.find()) paths.add(m.group(1));
        }
        return paths;
    }

    private String awaitChosenNamePath() throws IOException {
        final long deadline = SystemClock.uptimeMillis() + UI_WAIT_MS;
        List<String> paths = chosenNamePaths();
        while (paths.isEmpty() && SystemClock.uptimeMillis() < deadline) {
            SystemClock.sleep(POLL_MS);
            paths = chosenNamePaths();
        }
        assertEquals("one file under the chosen name: " + paths, 1, paths.size());
        return paths.get(0);
    }

    private void deleteChosenNameFiles() throws IOException {
        final StringBuilder script = new StringBuilder();
        for (String path : chosenNamePaths()) script.append("rm -f '").append(path).append("'\n");
        script.append("content delete --uri content://media/external/file --where \"_display_name LIKE '")
            .append(CHOSEN_NAME_LIKE).append("'\"\n");
        sh(script.toString());
    }

    private String boundNameNow() throws IOException {
        final Matcher m = BOUND_NAME.matcher(sh("run-as " + APP + " cat " + BINDING_PREFS + " 2>/dev/null\n"));
        return m.find() ? m.group(1) : "";
    }

    private String awaitBoundName() throws IOException {
        final long deadline = SystemClock.uptimeMillis() + UI_WAIT_MS;
        while (true) {
            final String name = boundNameNow();
            if (!name.isEmpty()) return name;
            if (SystemClock.uptimeMillis() > deadline) fail("the app bound no file");
            SystemClock.sleep(POLL_MS);
        }
    }

    /** Wait until the device log has a line matching `line`. */
    private void awaitLog(Pattern line) throws IOException {
        final long deadline = SystemClock.uptimeMillis() + UI_WAIT_MS;
        while (!line.matcher(sh("logcat -d\n")).find()) {
            if (SystemClock.uptimeMillis() > deadline) fail("no log line like " + line.pattern());
            SystemClock.sleep(POLL_MS);
        }
    }

    private String fileHash(String path) throws IOException {
        final String out = sh("md5sum '" + path + "'\n").trim();
        assertTrue("cannot read " + path + ": " + out, out.matches("[0-9a-f]{32} .*"));
        return out.substring(0, 32);
    }

    /** Wait until the file at `path` changes from `previous`; returns the new hash. */
    private String awaitFileHashOtherThan(String path, String previous) throws IOException {
        final long deadline = SystemClock.uptimeMillis() + UI_WAIT_MS;
        String hash;
        while ((hash = fileHash(path)).equals(previous)) {
            if (SystemClock.uptimeMillis() > deadline) fail(path + " was not rewritten");
            SystemClock.sleep(POLL_MS);
        }
        return hash;
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
