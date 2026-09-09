#!/usr/bin/env python3

import subprocess
import sys


def run(command):
    process = subprocess.Popen(command)
    try:
        awake = subprocess.Popen(
            [
                "/usr/bin/caffeinate",
                "-d",
                "-i",
                "-u",
                "-t",
                "240",
                "-w",
                str(process.pid),
            ]
        )
    except BaseException:
        process.terminate()
        process.wait()
        raise

    print(
        f"Temporary display assertion {awake.pid} bound to owned command "
        f"{process.pid}",
        flush=True,
    )
    try:
        return process.wait()
    finally:
        if awake.poll() is None:
            awake.terminate()
        awake.wait()
        print("Temporary display assertion released", flush=True)


def main(arguments):
    if not arguments:
        print("usage: run_with_display_awake.py command [argument ...]", file=sys.stderr)
        return 64
    return run(arguments)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
