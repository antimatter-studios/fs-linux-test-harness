# smoke-xattr.py <file> -- what the guest's kernel answers for an extended
# attribute whose name is not UTF-8, on the raw bytes (tests/smoke.sh, #274).
# Prints set=<errno name> when the set is refused, else the value read back
# as hex and whether the name is listed. The file is removed either way.
import errno, os, sys
f = sys.argv[1]
name = b"user.caf\xe9\xff"
open(f, "wb").close()
try:
    try:
        os.setxattr(f, name, b"\x01\x02")
    except OSError as e:
        print("set=" + errno.errorcode.get(e.errno, str(e.errno)))
        sys.exit(0)
    print("value=" + os.getxattr(f, name).hex())
    print("listed=" + str(name in [os.fsencode(n) for n in os.listxattr(f)]))
finally:
    os.remove(f)
