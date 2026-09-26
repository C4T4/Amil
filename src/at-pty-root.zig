extern fn at_pty_main(argc: c_int, argv: [*c][*c]u8) c_int;
extern fn _NSGetArgc() *c_int;
extern fn _NSGetArgv() *[*][*:0]u8;

pub fn main() u8 {
    const argc = _NSGetArgc().*;
    const argv = _NSGetArgv().*;
    return @intCast(at_pty_main(argc, @ptrCast(argv)));
}
