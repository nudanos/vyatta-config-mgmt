#!/usr/bin/env python3
"""Unit tests for get_cfg_version"""

import unittest
from unittest import mock
import get_cfg_version as gcv


class MenuDisplayTest(unittest.TestCase):
    """Unit Tests for displaying GRUB config recovery menu"""
    # Expected menu text
    PREVIOUS = "P\tPrevious\n"
    NEXT = "N\tNext\n"
    QUIT = "Q\tQuit and reboot\n"

    # testdata/ contains 3 test files - 4-commits, 8-commits and 15-commits
    # which contain subsets of the following options.
    ENTRY_0 = "0\t2016-11-22 09:58:27 by vyatta\n\tfirst\n"
    ENTRY_1 = "1\t2016-11-22 09:58:17 by configd\n\tsecond\n"
    ENTRY_2 = "2\t2016-11-22 09:57:11 by configd\n\tthird\n"
    ENTRY_3 = "3\t2016-11-22 09:56:59 by vyatta\n\tfourth\n"
    ENTRY_4 = "4\t2016-11-22 09:55:07 by vyatta\n\tfifth\n"
    ENTRY_5 = "5\t2016-11-22 09:54:57 by configd\n\tsixth\n"
    ENTRY_6 = "6\t2016-11-22 09:52:11 by configd\n\tseventh\n"
    ENTRY_7 = "7\t2016-11-22 09:41:59 by vyatta\n"
    ENTRY_8 = "8\t2016-11-22 09:41:47 by vyatta\n\tninth\n"
    ENTRY_9 = "9\t2016-11-22 09:41:37 by configd\n\ttenth\n"
    ENTRY_10 = "10\t2016-11-22 09:40:31 by configd\n\televenth\n"
    ENTRY_11 = "11\t2016-11-22 09:40:19 by vyatta\n\ttwelfth\n"
    ENTRY_12 = "12\t2016-11-22 09:38:27 by vyatta\n\tthirteenth\n"
    ENTRY_13 = "13\t2016-11-22 09:38:17 by configd\n\tfourteenth\n"
    ENTRY_14 = "14\t2016-11-22 09:35:31 by configd\n\tfifteenth\n"

    def test_4menu_num_options(self):
        """Check 4-option menu parsing returns correct number of options"""
        menu_options = gcv.read_menu_options("testdata/4-commits")
        self.assertEqual(len(menu_options), 4)

    def test_4menu_show_0_to_4(self):
        """Check 4 options are shown correctly with Q, but no P or N"""
        menu_options = gcv.read_menu_options("testdata/4-commits")
        menu_text = gcv.print_menu_subsection(menu_options, 0, 4)

        self.assertTrue(
            self.ENTRY_0 + self.ENTRY_1 + self.ENTRY_2 + self.ENTRY_3 +
            self.QUIT
            in menu_text)

        self.assertFalse(self.PREVIOUS in menu_text)
        self.assertFalse(self.ENTRY_4 in menu_text)
        self.assertFalse(self.NEXT in menu_text)

    def test_8menu_num_options(self):
        """Check 8-option menu parsing returns correct number of options"""
        menu_options = gcv.read_menu_options("testdata/8-commits")
        self.assertEqual(len(menu_options), 8)

    def test_8menu_show_5_to_9(self):
        """Check last 3 options shown correctly with P and Q.
        Checks suppression of N when fewer than 5 options."""
        menu_options = gcv.read_menu_options("testdata/8-commits")
        menu_text = gcv.print_menu_subsection(menu_options, 5, 9)

        self.assertTrue(
            self.PREVIOUS +
            self.ENTRY_5 + self.ENTRY_6 + self.ENTRY_7 +
            self.QUIT
            in menu_text)

        self.assertFalse(self.ENTRY_4 in menu_text)
        self.assertFalse(self.ENTRY_8 in menu_text)
        self.assertFalse(self.NEXT in menu_text)

    def test_15menu_num_options(self):
        """Check 15-option menu parsing returns correct number of options"""
        menu_options = gcv.read_menu_options("testdata/15-commits")
        self.assertEqual(len(menu_options), 15)

    def test_15menu_show_5_to_9(self):
        """Check middle 5 options shown correctly with P, N and Q"""
        menu_options = gcv.read_menu_options("testdata/15-commits")
        menu_text = gcv.print_menu_subsection(menu_options, 5, 9)

        self.assertTrue(
            self.PREVIOUS +
            self.ENTRY_5 + self.ENTRY_6 + self.ENTRY_7 +
            self.ENTRY_8 + self.ENTRY_9 +
            self.NEXT + self.QUIT
            in menu_text)

        self.assertFalse(self.ENTRY_4 in menu_text)
        self.assertFalse(self.ENTRY_10 in menu_text)

    def test_15menu_entry7_no_comment(self):
        """Check entry with no comment is handled correctly"""
        menu_options = gcv.read_menu_options("testdata/15-commits")
        menu_text = gcv.print_menu_subsection(menu_options, 5, 9)

        # Check no blank line in between the options
        expected = self.ENTRY_7 + self.ENTRY_8
        self.assertTrue(expected in menu_text)

    def test_15menu_show_10_to_14(self):
        """Check last 5 options shown correctly with P and Q.
        This tests suppression of N with a full 5 options in last set"""
        menu_options = gcv.read_menu_options("testdata/15-commits")
        menu_text = gcv.print_menu_subsection(menu_options, 10, 14)

        self.assertTrue(
            self.PREVIOUS +
            self.ENTRY_10 + self.ENTRY_11 + self.ENTRY_12 +
            self.ENTRY_13 + self.ENTRY_14 +
            self.QUIT
            in menu_text)

        self.assertFalse(self.ENTRY_9 in menu_text)
        self.assertFalse(self.NEXT in menu_text)


# Main program
if __name__ == "__main__":
    unittest.main()


class MenuChoiceTest(unittest.TestCase):
    """Unit tests for choosing a revision from the menu"""

    def choose(self, *answers):
        menu_options = gcv.read_menu_options("testdata/4-commits")
        with mock.patch.object(gcv.sp, "call"), \
                mock.patch("builtins.input", side_effect=list(answers)), \
                mock.patch("builtins.print"):
            return gcv.display_menu(menu_options)

    def test_last_revision(self):
        """Revisions 0-3 of 4 commits can be chosen"""
        self.assertEqual(self.choose("3"), 3)

    def test_one_past_the_last_revision(self):
        """4 commits have no revision 4: asked again, then Q"""
        self.assertEqual(self.choose("4", "", "q"), 0)
