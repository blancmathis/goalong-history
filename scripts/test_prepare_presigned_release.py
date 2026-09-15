#!/usr/bin/env python3
import pathlib, stat, tempfile, unittest, zipfile
from prepare_presigned_release import validate_archive

class PresignedArchiveTests(unittest.TestCase):
    def check_archive(self, entries, valid):
        with tempfile.TemporaryDirectory() as root:
            path = pathlib.Path(root) / 'input.zip'
            with zipfile.ZipFile(path, 'w') as archive:
                for name, body, mode in entries:
                    entry=zipfile.ZipInfo(name); entry.create_system=3; entry.external_attr=mode << 16
                    archive.writestr(entry, body)
            if valid: validate_archive(path)
            else:
                with self.assertRaises(ValueError): validate_archive(path)
    def test_regular_bundle_with_internal_framework_link(self):
        self.check_archive([('Goalong History.app/Contents/Info.plist', b'fixture', stat.S_IFREG|0o644),
            ('Goalong History.app/Contents/Frameworks/Sparkle.framework/Versions/Current', b'B', stat.S_IFLNK|0o777),
            ('Goalong History.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle', b'code', stat.S_IFREG|0o755)], True)
    def test_parent_traversal(self):
        self.check_archive([('Goalong History.app/../../outside', b'x',stat.S_IFREG|0o644)], False)
    def test_absolute_path(self):
        self.check_archive([('/Applications/Other.app', b'x',stat.S_IFREG|0o644)], False)
    def test_other_bundle(self):
        self.check_archive([('Other.app/Contents/Info.plist', b'x',stat.S_IFREG|0o644)], False)
    def test_external_symbolic_link(self):
        self.check_archive([('Goalong History.app/link', b'../../outside',stat.S_IFLNK|0o777)], False)
    def test_absolute_symbolic_link(self):
        self.check_archive([('Goalong History.app/link', b'/Applications',stat.S_IFLNK|0o777)], False)
    def test_write_through_symbolic_link(self):
        self.check_archive([('Goalong History.app/link', b'Contents',stat.S_IFLNK|0o777),
            ('Goalong History.app/link/file',b'x',stat.S_IFREG|0o644)], False)
    def test_device_node(self):
        self.check_archive([('Goalong History.app/node', b'',stat.S_IFCHR|0o600)], False)
    def test_backslash(self):
        self.check_archive([('Goalong History.app/..\\outside', b'x',stat.S_IFREG|0o644)], False)

if __name__=='__main__': unittest.main()
