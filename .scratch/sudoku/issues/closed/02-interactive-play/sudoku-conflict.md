Validator (validator.zig) — no Board
Method	Signature	When
Whole board
detectConflicts(cells: []const Cell) u128
Load, end of generate, tests
One cell
detectConflictsForCell(cells: []const Cell, row: u8, col: u8) u128
After single setCell
Row/col/box helpers are private inside Validator — not part of the public API.

Board (board.zig) — imports Validator
Method	Signature	Calls
Whole board
flagConflicts(self: *Board) void
Validator.detectConflicts(self.cells[0..])
One cell
refreshConflictsForCell(self: *Board, row: u8, col: u8) void
clears row∪col∪box bits, then Validator.detectConflictsForCell(...)
Wiring
// After one edit (play / solver)
self.refreshConflictsForCell(row, col);
// After bulk load or generation done
self.flagConflicts();
Validator only sees []const Cell. Board owns cells, conflict_bits, and the mask clear/OR for incremental updates.

Split into your repo as validator.zig + board.zig and drop the shared Cell / constants into your existing types module if you already have them there.
