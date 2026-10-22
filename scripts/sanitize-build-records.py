"""Remove machine-specific prefixes while preserving decoder build options."""
import sys
from pathlib import Path
root = str(Path(__file__).resolve().parent.parent)
home = str(Path.home())
for argument in sys.argv[1:]:
    path = Path(argument)
    path.write_text(path.read_text().replace(root, '<build-root>').replace(home, '<home>'))
