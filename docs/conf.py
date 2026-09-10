"""Sphinx configuration for the QPSK Jupiter Modem docs."""

project = "QPSK Jupiter Modem"
author = "QPSK Jupiter Modem contributors"
release = "0.1.0"

extensions = [
    "sphinx.ext.githubpages",
    "sphinx.ext.napoleon",
    "sphinx.ext.graphviz",
    "myst_parser",
    "adi_doctools",
]
needs_extensions = {"adi_doctools": "0.4.21"}
html_theme = "cosmic"
html_static_path = ["_static"]
# Publish the pre-built boot image bank (BOOT.BIN.* + MD5SUMS + README) at the
# site root so they are downloadable without repository access.
html_extra_path = ["../images"]
# The legacy hand-written .md notes that predated this Sphinx tree were folded
# into the .rst pages and deleted (Task 11); their originals are recoverable at
# tag archive/pre-cleanup-2026-09-09.
exclude_patterns = [
    "_build",
    "superpowers",  # campaign working plans/specs, not user documentation
    "evidence",     # verbatim ledgers, linked by path, not rendered
]
