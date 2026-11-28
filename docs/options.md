# Options

securl takes these options of curl, with curl's syntax, messages and exit codes:

`-A` `-b` `-c` `-j` `-d` `--data-ascii` `--data-raw` `--data-binary` `--data-urlencode` `--json`
`-F` `--form-string` `--form-escape` `-D` `-e` `-f` `--fail-with-body` `-G` `-H` `-I` `-i` `-k`
`--cacert` `--capath` `-E` `--cert-type` `--key` `--key-type` `--pass` `-L` `--location-trusted`
`--max-redirs` `-o` `-O` `--remote-name-all` `--output-dir` `-g` `-r` `-s` `-S` `-T` `-u`
`--digest` `--basic` `--anyauth` `-v` `-w` `-X` `-x` `-U` `-p` `--proxytunnel`
`--suppress-connect-headers` `--proxy-insecure` `--proxy-cacert` `--proxy-capath` `--socks4`
`--socks4a` `--socks5` `--socks5-hostname` `--hsts` `--proxy-digest` `--proxy-basic`
`--proxy-anyauth` `--noproxy` `--resolve` `--connect-to` `--unix-socket` `--path-as-is` `--raw`
`-0` `--http1.1` `--http2` `--http2-prior-knowledge` `--url` `-m` `--connect-timeout`
`--compressed` `--tr-encoding` `--keepalive` `--keepalive-time` `--keepalive-cnt`
`--tcp-nodelay` `--limit-rate` `--max-filesize` `--remove-on-error` `--next` `-K` `--stderr`
`--retry` `--retry-delay` `--retry-max-time` `--retry-connrefused` `--retry-all-errors` `-C`
`-J` `-M` `-h` `-V` `-q` `--trace-ascii` `--trace-time` `-z` `--etag-save` `--etag-compare` `-n`
`--netrc-optional` `--netrc-file`.

## Notes

- **`--next` and `-K`:** groups and config files work as in curl. The tool reads `-K` files,
  and hands their lines to the parser, which cannot open a file.
- **Globs:** `{a,b}` and `[1-10:2]` in a URL or a `-T` name, `#1` and `#<name>` in `-o`.
  Each URL takes the `-o`, `-O` and `-T` of its position, as in curl.
- **`--url @FILE`:** reads one URL on each line, each as with `-O`.
- **`-w`:** most of curl's variables, `%header{}`, `%output{}`, and the `%{time_*}` timers.
- **`--retry` and `-C`:** curl's retry rules and waits, and its resume checks.
- **`-z`:** takes a date. With a file name, securl drops the condition with a warning, because
  Vx's `std::fs` cannot read the time of a file yet.
- **`.netrc`:** the entry for each host of a transfer, also after a redirect, goes only to
  that host, as in curl.
- **Proxies:** `-x`, the proxy variables of the environment, `--noproxy`, and SOCKS 4, 4a, 5
  and 5h, also over a Unix-domain socket.

securl accepts 19 of the top 20 options of the 2025 curl user survey. It has no `--libcurl`.
