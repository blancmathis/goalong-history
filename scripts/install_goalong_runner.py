#!/usr/bin/env python3
"""GitHub runner installation disabled: the owner approved local auto-deploy.

The initially installed runner has been stopped, unregistered and removed.
An origin hook is defense in depth: runner v2.338.0 can still execute steps with
always()/failure() after that hook fails. Do not register or start this owner's
Mac for the public repository. See docs/fast-deploy-report-20261011.md.
"""
import argparse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--start", action="store_true", help="Reserved; registration and activation are currently blocked")
    parser.parse_args()
    parser.error(
        "Public runner admission is unsafe with an origin hook alone. "
        "Use install_local_auto_deploy.py; the owner approved an outbound-only "
        "local coordinator instead of a GitHub runner."
    )


if __name__ == "__main__":
    main()
