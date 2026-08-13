extern fn print(i32) void;

export fn greet(a: i32, b: i32) void {
    // print the sum so we can verify through the extern callback
    print(a + b);
}
