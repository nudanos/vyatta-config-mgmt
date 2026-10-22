#!/usr/bin/env python3
"""Utility to read 'commits' file, display as a menu, and return numeric
   value of user's choice (0 being no-op)."""

import argparse
import subprocess as sp
from datetime import datetime

#
# If we assume 20 lines, and a comment for each commit, plus 3 lines for
# banner, 1 each for P, N and Q options, plus 2 for space and prompt, and
# a couple more for 'invalid reponse, press any key', we are down to 10
# lines for config options making 5 commits max unless we vary it depending
# on number of comments.  Probably best not so it is at least consistent
# in terms of number of options.
#
MAX_ENTRIES_PER_PAGE = 5

#
# PROMPT asking user to choose
#
PROMPT = "Please choose option: "

#
# Format of the 'commits' file, which details previous commits,
# is as shown, with the first field (before first '|') being empty.
#
# nil | time | user | via | comment |
#
# |1475238877|root|grub|Restored via GRUB menu|
# |1475238004|configd|other||
#
TIMESTAMP = 1
USER = 2
VIA = 3
COMMENT = 4


#
# print_banner
#
def print_banner():
    """Clear screen and print menu title banner"""

    _ = sp.call('clear', shell=True)
    print("Configuration Recovery")
    print("======================")
    print("")


#
# print_menu_subsection
#
def print_menu_subsection(options, first, last):
    """Print section of menu from <first> to <last> item inclusive, checking
    that they exist.  If this is not first subsection, print 'P'rev, and if
    not last, print 'N'ext.  Always offer 'Q'uit.

    Aim is to present options in similar fashion to the 'show system commit'
    command, eg:

    vyatta@vm-GRUB615-1:~$ show sys com
    0   2016-09-30 12:34:37 by root
        Restored via GRUB menu
    1   2016-09-30 12:20:04 by configd
    2   2016-09-30 12:19:27 by root
        Restored via GRUB menu
    3   2016-09-30 12:17:50 by vyatta
        EEEEE

    """

    menu = ""
    if first != 0:
        menu += "P\tPrevious\n"

    all_present_and_correct = True
    index = 0
    for index in range(first, last + 1):
        if index >= len(options):
            # If one missing, won't be any more after it.
            all_present_and_correct = False
            break
        menu_entry = options[index]
        readable_time = datetime.fromtimestamp(int(menu_entry[TIMESTAMP]))
        menu += f"{index}\t{readable_time} by {menu_entry[USER]}\n"

        # We have a comment so print it.
        if menu_entry[COMMENT] != "":
            menu += f"\t{menu_entry[COMMENT]}\n"

    if all_present_and_correct and index < (len(options) - 1):
        menu += "N\tNext\n"

    menu += "Q\tQuit and reboot\n"

    return menu


# Initial menu
def display_menu(options):
    """Loop showing menu options until Q or valid config-version chosen"""

    num_entries = len(options)
    first = 0
    last = MAX_ENTRIES_PER_PAGE - 1

    while True:
        print_banner()
        menu = print_menu_subsection(options, first, last)
        print(menu)

        option = input(PROMPT)

        if option in ('p', 'P') and first != 0:
            first = first - MAX_ENTRIES_PER_PAGE
            last = last - MAX_ENTRIES_PER_PAGE
            continue

        if option in ('n', 'N') and last < num_entries:
            first = first + MAX_ENTRIES_PER_PAGE
            last = last + MAX_ENTRIES_PER_PAGE
            continue

        if option in ('q', 'Q'):
            option = '0'
            break

        # Check for numeric value; revisions run 0 to num_entries - 1
        # (num_entries itself was accepted, one past the last)
        try:
            revision = int(option)
            if first <= revision <= last and revision < num_entries:
                break
            print(f"Invalid config version: {option}")
            input("Press any key to continue ...")
        except ValueError:
            print(f"Invalid option: {option}")
            input("Press any key to continue ...")

    # User wishes to continue booting.  If option = 0, this is a no-op.
    # If > 0, config is to be replaced.
    return int(option)


#
# read_menu_options
#
def read_menu_options(filename):
    """Read 'commits' file provided into a list"""

    # Set up menu_actions
    try:
        with open(filename, "r", encoding="utf-8") as version_fh:
            raw_versions = version_fh.readlines()
    except IOError:
        print("Unable to find previous revisions.\n")
        return None

    options = []
    for line in raw_versions:
        options.append(line.split("|"))
    return options


def get_cli_params():
    """Parse command line arguments"""

    parser = argparse.ArgumentParser(usage='''%(prog)s [options]

This script takes a BVNOS commit history file and presents it as a menu
to the user.  A maximum of 5 options are displayed at one time, with
'N' for next and 'P' for previous being displayed as appropriate.  'Q'
is also offered to quit.

The script returns the numeric value of the option chosen, or 0 for
error / no-op (config version 0 = current version).
''')

    parser.add_argument("-f", "--filename", help="Commit History File")
    return parser.parse_args()


def get_config_version():
    """Return user's chosen configuration version"""

    # Get and check filename
    args = get_cli_params()
    if not args.filename:
        print("Filename required.")
        return 0

    # Print menu and get user's choice.
    menu_options = read_menu_options(args.filename)
    if menu_options:
        return display_menu(menu_options)
    return 0
