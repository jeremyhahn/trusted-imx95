"""Write a PAX tar fixture for test/platform_image_repro_test.sh.

usage: repro_tar_fixture.py OUT.tar KEY=VALUE ...
Keys: xattr, cap, lcap, acl (PAX header values on usr/bin/tool), dev (MAJOR:MINOR of dev/null).
"""
import io
import sys
import tarfile

out = sys.argv[1]
opt = dict(a.split("=", 1) for a in sys.argv[2:])
with tarfile.open(out, "w", format=tarfile.PAX_FORMAT) as t:
    def add(name, data=b"", **kw):
        ti = tarfile.TarInfo(name)
        ti.mtime = 0
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = ""
        ti.mode = kw.pop("mode", 0o644)
        ti.pax_headers = kw.pop("pax", {})
        for k, v in kw.items():
            setattr(ti, k, v)
        if ti.type == tarfile.REGTYPE:
            ti.size = len(data)
            t.addfile(ti, io.BytesIO(data))
        else:
            t.addfile(ti)

    add("etc/issue", b"issue")
    pax = {}
    if "xattr" in opt:
        pax["SCHILY.xattr.user.tag"] = opt["xattr"]
    if "cap" in opt:
        pax["SCHILY.xattr.security.capability"] = opt["cap"]
    if "lcap" in opt:
        pax["LIBARCHIVE.xattr.security.capability"] = opt["lcap"]
    if "acl" in opt:
        pax["SCHILY.acl.access"] = opt["acl"]
    add("usr/bin/tool", b"hello", mode=0o755, pax=pax)
    major, minor = (opt.get("dev", "1:3")).split(":")
    add("dev/null", type=tarfile.CHRTYPE, devmajor=int(major), devminor=int(minor), mode=0o666)
