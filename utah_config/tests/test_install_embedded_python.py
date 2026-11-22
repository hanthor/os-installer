"""Tests for the Python heredocs embedded in utah_config/scripts/install.sh.

The install script needs root, a live medium and a target disk, so it cannot
run in a unit test. Its three `python3 - ... <<'PY'` blocks are pure logic over
files, though: the systemd-repart definitions generated from the medium's
partition table, the FAT volume serial rewrite, and the GRUB environment block
rewrite. They are extracted verbatim from the script and run as written, so a
change to the script is what gets tested.

Run from the repository root:

    python3 -m unittest discover -s utah_config/tests -v
"""

import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "install.sh"

BIOS_BOOT_TYPE = "21686148-6449-6e6f-744e-656564454649"
ESP_TYPE = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
ROOT_TYPE = "4f68bce3-e8cd-4db1-96e7-fbcaf984b709"
LINUX_TYPE = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"


def heredocs():
    """Return the bodies of the script's python3 heredocs, in file order."""
    text = SCRIPT.read_text()
    return re.findall(r"python3 - [^\n]*<<'PY'\n(.*?)\nPY\n", text, re.S)


def run_block(index, *args, **kwargs):
    body = heredocs()[index]
    return subprocess.run(
        [sys.executable, "-I", "-c", body, *map(str, args)],
        capture_output=True, text=True, check=True, **kwargs)


class ScriptShape(unittest.TestCase):
    def test_three_python_blocks_in_known_order(self):
        blocks = heredocs()
        self.assertEqual(len(blocks), 3)
        self.assertIn("CopyBlocks=", blocks[0])
        self.assertIn("FAT32", blocks[1])
        self.assertIn("saved_entry", blocks[2])

    def test_bash_syntax(self):
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True)


class RepartDefinitions(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.out = self.tmp / "repart.d"
        self.out.mkdir()

    def generate(self, partitions, encrypt, sectorsize=None):
        table = {"label": "gpt", "partitions": partitions}
        if sectorsize is not None:
            table["sectorsize"] = sectorsize
        medium = self.tmp / "medium.json"
        medium.write_text(json.dumps({"partitiontable": table}))
        run_block(0, medium, self.out, "/dev/vda3", "1" if encrypt else "0", BIOS_BOOT_TYPE)
        return {p.name: p.read_text() for p in sorted(self.out.iterdir())}

    def medium(self):
        return [
            {"node": "/dev/vda1", "start": 2048, "size": 2048, "type": BIOS_BOOT_TYPE.upper()},
            {"node": "/dev/vda2", "start": 4096, "size": 4096, "type": ESP_TYPE, "name": "EFI"},
            {"node": "/dev/vda3", "start": 8192, "size": 20480, "type": ROOT_TYPE, "name": "root"},
        ]

    def test_bios_boot_skipped_and_numbering_kept(self):
        files = self.generate(self.medium(), encrypt=False)
        self.assertEqual(list(files), ["02-copy.conf", "03-copy.conf"])

    def test_fixed_partition_pinned_to_its_size(self):
        esp = self.generate(self.medium(), encrypt=False)["02-copy.conf"]
        self.assertEqual(
            esp.splitlines(),
            ["[Partition]", f"Type={ESP_TYPE.lower()}", "CopyBlocks=/dev/vda2",
             "Label=EFI", f"SizeMinBytes={4096 * 512}", f"SizeMaxBytes={4096 * 512}"])

    def test_root_may_grow(self):
        root = self.generate(self.medium(), encrypt=False)["03-copy.conf"]
        self.assertIn(f"SizeMinBytes={20480 * 512}", root)
        self.assertNotIn("SizeMaxBytes", root)
        self.assertNotIn("Encrypt=", root)

    def test_encrypted_root_reserves_luks_header(self):
        root = self.generate(self.medium(), encrypt=True)["03-copy.conf"]
        self.assertIn(f"SizeMinBytes={20480 * 512 + (32 << 20)}", root)
        self.assertIn("Encrypt=key-file", root)

    def test_encryption_leaves_other_partitions_alone(self):
        plain = self.generate(self.medium(), encrypt=False)["02-copy.conf"]
        for f in self.out.iterdir():
            f.unlink()
        self.assertEqual(self.generate(self.medium(), encrypt=True)["02-copy.conf"], plain)

    def test_sector_size_from_table(self):
        files = self.generate(self.medium(), encrypt=False, sectorsize=4096)
        self.assertIn(f"SizeMaxBytes={4096 * 4096}", files["02-copy.conf"])

    def test_unnamed_partition_has_no_label(self):
        parts = self.medium()
        del parts[1]["name"]
        self.assertNotIn("Label=", self.generate(parts, encrypt=False)["02-copy.conf"])


class FatSerial(unittest.TestCase):
    """The volume serial lives at 0x43 (FAT32) or 0x27 (FAT12/16)."""

    def image(self, fat32, backup_sector=0):
        sector = bytearray(512)
        sector[11:13] = struct.pack("<H", 512)  # bytes per sector
        if fat32:
            sector[82:90] = b"FAT32   "
            sector[50:52] = struct.pack("<H", backup_sector)
        else:
            sector[54:62] = b"FAT16   "
        return sector

    def rewrite(self, content):
        with tempfile.NamedTemporaryFile() as f:
            f.write(content)
            f.flush()
            out = run_block(1, f.name).stdout.strip()
            return out, Path(f.name).read_bytes()

    def test_fat32_primary_and_backup_updated(self):
        original = bytes(self.image(fat32=True, backup_sector=6)) + bytes(512 * 9)
        out, after = self.rewrite(original)
        serial = struct.unpack("<I", after[0x43:0x47])[0]
        self.assertEqual(out, "%04X-%04X" % (serial >> 16, serial & 0xFFFF))
        self.assertEqual(after[6 * 512 + 0x43:6 * 512 + 0x47], after[0x43:0x47])
        # nothing but the two serials changed
        self.assertEqual(len(after), len(original))
        changed = {i for i, (a, b) in enumerate(zip(original, after)) if a != b}
        self.assertTrue(changed <= set(range(0x43, 0x47)) | set(range(6 * 512 + 0x43, 6 * 512 + 0x47)))

    def test_fat32_without_backup_sector(self):
        original = bytes(self.image(fat32=True, backup_sector=0)) + bytes(512 * 9)
        out, after = self.rewrite(original)
        serial = struct.unpack("<I", after[0x43:0x47])[0]
        self.assertEqual(out, "%04X-%04X" % (serial >> 16, serial & 0xFFFF))
        self.assertEqual(after[512:], original[512:])

    def test_fat16_uses_old_offset_and_no_backup(self):
        original = bytes(self.image(fat32=False)) + bytes(512 * 9)
        out, after = self.rewrite(original)
        serial = struct.unpack("<I", after[0x27:0x2B])[0]
        self.assertEqual(out, "%04X-%04X" % (serial >> 16, serial & 0xFFFF))
        self.assertEqual(after[0x43:0x47], original[0x43:0x47])
        self.assertEqual(after[512:], original[512:])

    def test_serial_is_random(self):
        original = bytes(self.image(fat32=True)) + bytes(512)
        serials = {self.rewrite(original)[0] for _ in range(4)}
        self.assertGreater(len(serials), 1)


class GrubEnv(unittest.TestCase):
    HEADER = "# GRUB Environment Block\n"

    def block(self, *lines):
        body = self.HEADER + "".join(l + "\n" for l in lines)
        return body + "#" * (1024 - len(body))

    def rewrite(self, content, live="utah-live"):
        with tempfile.NamedTemporaryFile("w+") as f:
            f.write(content)
            f.flush()
            run_block(2, f.name, live)
            return Path(f.name).read_text()

    def test_live_default_removed_and_others_kept(self):
        after = self.rewrite(self.block("saved_entry=utah-live", "boot_counter=3"))
        self.assertEqual(after, self.block("boot_counter=3"))

    def test_other_saved_entry_kept(self):
        before = self.block("saved_entry=utah-deploy")
        self.assertEqual(self.rewrite(before), before)

    def test_block_stays_exactly_1024_bytes(self):
        for lines in ((), ("saved_entry=utah-live",), ("a=b", "saved_entry=utah-live")):
            after = self.rewrite(self.block(*lines))
            self.assertEqual(len(after), 1024)
            self.assertTrue(after.startswith(self.HEADER))

    def test_only_the_named_distribution_is_removed(self):
        before = self.block("saved_entry=utah-live")
        self.assertEqual(self.rewrite(before, live="dakota-live"), before)

    def test_prefix_of_live_name_is_not_removed(self):
        before = self.block("saved_entry=utah-live-2")
        self.assertEqual(self.rewrite(before), before)


if __name__ == "__main__":
    unittest.main()
