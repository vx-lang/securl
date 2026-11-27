# Vx issues found while writing securl

Fixed in Vx:

- [#3998](https://github.com/vx-lang/Vx/issues/3998): the check of an `else if` chain doubled with each link.
- [#3999](https://github.com/vx-lang/Vx/issues/3999), [#4092](https://github.com/vx-lang/Vx/issues/4092): the audit and `--no-trusted-code` counted the wrong code.
- [#4000](https://github.com/vx-lang/Vx/issues/4000): standard output lost its last line at the end of the program.
- [#4001](https://github.com/vx-lang/Vx/issues/4001): the flat code generator declined `?` on some results.
- [#4002](https://github.com/vx-lang/Vx/issues/4002), [#4003](https://github.com/vx-lang/Vx/issues/4003), [#4004](https://github.com/vx-lang/Vx/issues/4004), [#4010](https://github.com/vx-lang/Vx/issues/4010): checks that refused correct code, and no `as_mut` for an `Option`.
- [#4005](https://github.com/vx-lang/Vx/issues/4005): no safe way to the terminal, the command line or the environment.
- [#4118](https://github.com/vx-lang/Vx/issues/4118), [#4142](https://github.com/vx-lang/Vx/issues/4142): a value moved out and freed twice.
- [#4120](https://github.com/vx-lang/Vx/issues/4120), [#4131](https://github.com/vx-lang/Vx/issues/4131), [#4181](https://github.com/vx-lang/Vx/issues/4181): `std::net` had no name lookup, no Unix-domain socket, and no `TcpStream::fd`.
- [#4132](https://github.com/vx-lang/Vx/issues/4132): `std::fs` could not remove a file or tell its kind.
- [#4172](https://github.com/vx-lang/Vx/issues/4172): code generation panicked on `match f()?`.

Open:

- [#532](https://github.com/vx-lang/Vx/issues/532): string literals have no type of their own, so `tools/check-no-pointers.sh` keeps raw pointers out of the safe code.
- [#4119](https://github.com/vx-lang/Vx/issues/4119): a command-line word must be UTF-8.
- Fields have no visibility levels yet, so `tools/check-secrets.sh` keeps password reads in `auth.vx`.
