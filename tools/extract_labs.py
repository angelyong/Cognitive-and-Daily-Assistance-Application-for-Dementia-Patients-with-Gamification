from pathlib import Path
import sys
from lxml import html


ALL_LABS = [
    Path(r"C:\Users\angel\Downloads\Y3S3\cyber\Practical\Lab3\Crypto_Lab_I.html"),
    Path(r"C:\Users\angel\Downloads\Y3S3\cyber\Practical\Lab4\Crypto_Lab_II.html"),
    Path(r"C:\Users\angel\Downloads\Y3S3\cyber\Practical\Lab5\Crypto_Lab_III.html"),
]

sys.stdout.reconfigure(encoding="utf-8")
LABS = ALL_LABS
if len(sys.argv) > 1:
    needle = sys.argv[1].lower()
    LABS = [path for path in ALL_LABS if needle in path.name.lower()]


for path in LABS:
    doc = html.fromstring(path.read_bytes())
    print(f"\n{'=' * 28} {path.name} {'=' * 28}\n")
    for element in doc.xpath("//body//*[self::h1 or self::h2 or self::h3 or self::h4 or self::p or self::li or self::pre]"):
        # Avoid printing paragraph/list content twice when it is nested in another selected element.
        if any(parent.tag in {"p", "li", "pre"} for parent in element.iterancestors()):
            continue
        text = " ".join(element.text_content().split())
        if not text:
            continue
        prefix = {
            "h1": "# ",
            "h2": "## ",
            "h3": "### ",
            "h4": "#### ",
            "li": "- ",
            "pre": "    ",
        }.get(element.tag, "")
        print(prefix + text)
