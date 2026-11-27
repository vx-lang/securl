#!/usr/bin/env python3
"""List the curl HTTP tests that use only options securl implements.

    python3 tests/scan-supported-tests.py CURL_SRC/tests/data [tests/supported-tests.txt]

It reads each test file of curl's suite, keeps the tests with the keyword HTTP that need only
the plain HTTP test server and run the curl tool, and checks the options of their command line.
It prints which missing options block the most tests. With a second argument, it writes the
numbers of the tests that need no missing option to that file.

Keep SUPPORTED_LONG and SUPPORTED_SHORT the same as the options in src/securl/options.vx.
"""
import collections
import os
import re
import shlex
import sys

SUPPORTED_LONG = set("""
user-agent cookie data data-ascii data-raw data-binary data-urlencode json dump-header referer
header max-time connect-timeout output range upload-file user write-out request url max-redirs
resolve connect-to trace-ascii trace http1.0 http1.1 fail fail-with-body get include
show-headers head insecure location location-trusted remote-name remote-name-all disable silent
show-error verbose version help globoff path-as-is trace-time progress-bar no-progress-meter
buffer raw compressed proxy proxy-user noproxy output-dir digest basic anyauth proxy-digest
proxy-basic proxy-anyauth form form-string form-escape cookie-jar junk-session-cookies cacert capath
http2 http2-prior-knowledge tcp-nodelay keepalive keepalive-time keepalive-cnt proxytunnel
socks4 socks4a socks5 socks5-hostname cert cert-type key key-type pass compressed tr-encoding hsts
suppress-connect-headers proxy-insecure proxy-cacert proxy-capath remove-on-error limit-rate
max-filesize next config retry retry-delay retry-max-time retry-connrefused
retry-all-errors
""".split())
SUPPORTED_SHORT = set("AbcdDeFHjmorTuwXxU0fGiIkLOqsSvVhg#NpE:K")
# The short options that take a value: the rest of the word is that value.
SHORT_WITH_VALUE = set("AbcdDeFHmorTuwXxUEK")


def http_tests(data):
    """Yield (name, command) for each HTTP test that runs the curl tool on the HTTP server."""
    for name in sorted(os.listdir(data)):
        if not re.fullmatch(r"test\d+", name):
            continue
        text = open(os.path.join(data, name), encoding="latin-1").read()
        if not re.search(r"<keywords>[^<]*\bHTTP\b", text):
            continue
        server = re.search(r"<server>\s*(.*?)\s*</server>", text, re.S)
        if not server or server.group(1).split() != ["http"]:
            continue
        if re.search(r"<tool>|type=\"(perl|shell)\"", text):
            continue
        # runtests.pl runs a C program of the curl build for these, not the curl tool.
        if re.search(r"<keywords>[^<]*^(libtest|unittest|tunittest)$", text, re.M):
            continue
        command = re.search(r"<command[^>]*>\s*(.*?)\s*</command>", text, re.S)
        if command:
            yield name, " ".join(command.group(1).split("\n"))


def missing_options(command):
    """The options of a command line that securl does not implement."""
    try:
        words = shlex.split(command)
    except ValueError:
        words = command.split()
    missing = set()
    for word in words:
        if word.startswith("--"):
            option = word[2:].split("=", 1)[0]
            base = option[3:] if option.startswith("no-") else option
            if option not in SUPPORTED_LONG and base not in SUPPORTED_LONG:
                missing.add(word)
        elif word.startswith("-") and len(word) > 1:
            for letter in word[1:]:
                if letter not in SUPPORTED_SHORT:
                    missing.add("-" + letter)
                    break
                if letter in SHORT_WITH_VALUE:
                    break
    return missing


def main():
    data = sys.argv[1]
    counts = collections.Counter()
    supported = []
    total = 0
    for name, command in http_tests(data):
        total += 1
        missing = missing_options(command)
        counts.update(missing)
        if not missing:
            supported.append(int(name[4:]))
    print(f"HTTP tests that run curl on the HTTP server: {total}")
    print(f"tests that use only options securl implements: {len(supported)}")
    for option, n in counts.most_common(30):
        print(f"{n:5d} {option}")
    if len(sys.argv) > 2:
        with open(sys.argv[2], "w") as out:
            for number in sorted(supported):
                out.write(f"{number}\n")


if __name__ == "__main__":
    main()
