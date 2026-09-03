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
html_extra_path = ["../boot_known_good"]
# The legacy hand-written .md notes that predate this Sphinx tree are kept on
# disk but are not part of the rendered site (they are superseded by, and in
# places contradicted by, the evidence-anchored two_jup/*.md ledgers the .rst
# pages cite).
exclude_patterns = [
    "_build",
    "superpowers",  # campaign working plans/specs, not user documentation
    "ARCHITECTURE.md",
    "BRINGUP.md",
    "BRINGUP_F1536_RESULTS.md",
    "BUILD.md",
    "DEBUGGING.md",
    "DEPLOY_F1536.md",
    "EVM_BUDGET.md",
    "GLOSSARY.md",
    "LINK_CHARACTERIZATION.md",
    "PORTING.md",
    "PROVENANCE.md",
    "TESTING.md",
]
