#!/usr/bin/env python3
"""Write tests/unit/size_parameter.vx from the table of curl's unit test tool1623, which checks
how curl reads a size such as `2k` or `1.5M` for --limit-rate (GetSizeParameter).

    python3 tools/gen-size-test.py CURL_SRC > tests/unit/size_parameter.vx
"""
import re
import sys

MESSAGES = {
    "PARAM_BAD_USE": "is badly used here",
    "PARAM_BAD_NUMERIC": "expected a proper numerical parameter",
    "PARAM_NUMBER_TOO_LARGE": "too large number",
}

HEAD = '''// Checks how securl::options reads a size for --limit-rate, with the table of curl's unit test
// tool1623 (GetSizeParameter). Made by tools/gen-size-test.py.
import core::result;
import std::vec;
import sys::text;
import securl::bytes;
import securl::failure;
import securl::options;

fn args_of(value : *const i8) -> Vec<Vec<u8>> {
  let mut v = Vec<Vec<u8>>::new();
  v.push(lit("--limit-rate"));
  v.push(lit(value));
  v.push(lit("http://h/"));
  return v;
}

/// Whether `--limit-rate value` gives `want` bytes per second.
fn reads_as(value : *const i8, want : i64) -> bool {
  match parse_args(&args_of(value)) {
    Result<Config, Failure>::Ok(c) => {
      return c.limit_rate == want;
    },
    Result<Config, Failure>::Err(_f) => {
      return false;
    }
  }
}

/// Whether `--limit-rate value` fails with exit code 2 and `message`.
fn refused(value : *const i8, message : *const i8) -> bool {
  match parse_args(&args_of(value)) {
    Result<Config, Failure>::Ok(_c) => {
      return false;
    },
    Result<Config, Failure>::Err(f) => {
      let mut want = lit("option --limit-rate: ");
      push_lit(&mut want, message);
      return f.code == FAILED_INIT && same_bytes(&f.message, &want);
    }
  }
}

fn main() -> i32 {'''


def main():
    text = open(sys.argv[1] + "/tests/tunit/tool1623.c").read()
    table = text[text.index("check1623 check[] = {"):]
    table = table[:table.index("{ NULL")]
    lines = [HEAD]
    for value, amount, err in re.findall(r'\{ "([^"]*)", (-?\d+), (PARAM_\w+) \}', table):
        if err == "PARAM_OK":
            lines.append(f'  assert(reads_as("{value}", {amount}i64), "{value}");')
        else:
            lines.append(f'  assert(refused("{value}", "{MESSAGES[err]}"), "{value}");')
    lines.append("  return 0;\n}")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
