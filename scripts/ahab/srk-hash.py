"""srk-hash.py: print the AHAB SRK table hash of the srk_array of a config.

Run by srk-hash-check.sh with the pinned SPSDK venv's python, as
`python -I srk-hash.py <config.yaml>` from the work directory of that script.
It loads the configuration with SPSDK (no signing, no export, no fuse script)
and prints the hash as upper-case hex on one line.
"""

import sys

from spsdk.image.ahab.ahab_image import AHABImage
from spsdk.utils.config import Config


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: srk-hash.py <config.yaml>", file=sys.stderr)
        return 2
    image = AHABImage.load_from_config(Config.create_from_file(sys.argv[1]))
    print(image.ahab_containers[0].get_srk_hash().hex().upper())
    return 0


if __name__ == "__main__":
    sys.exit(main())
