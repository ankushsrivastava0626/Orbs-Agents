"""Keep the voice command path in RAM on a small-memory Mac, so a command never waits for it to be read back
from disk (that's what made "got it" take 20-40 s): pins the speech-to-text model files (shared
with every macparakeet-cli run through the page cache), and the voice server's own model weights."""
import ctypes, ctypes.util, glob, os, threading, time

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
libc.mmap.restype = ctypes.c_void_p
libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_long]
libc.mlock.argtypes = libc.munlock.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
libc.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
PROT_READ, MAP_SHARED, MAP_FAILED = 1, 1, ctypes.c_void_p(-1).value

HOME = os.path.expanduser("~")
STT_FILES = [HOME + "/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3",
             HOME + "/Library/Caches/com.macparakeet.MacParakeet/com.apple.e5rt.e5bundlecache"]
# not the macparakeet-cli program itself: macOS kills a signed program at launch if another process has its file pinned
pinned = {}                                     # path -> (address, size, mtime)
stats = {"files_mb": 0.0, "weights_mb": 0.0}

def _files():
    for root in STT_FILES:
        if os.path.isfile(root): yield root
        for p in glob.glob(root + "/**/*", recursive=True):
            if os.path.isfile(p) and not os.path.islink(p): yield p

def pin_files():
    """Map each file read-only and lock it; files that changed or went away are let go and redone."""
    seen = set()
    for p in _files():
        try: st = os.stat(p)
        except OSError: continue
        seen.add(p)
        old = pinned.get(p)
        if old and old[2] == st.st_mtime and old[1] == st.st_size: continue
        if old: _unpin(p)
        if st.st_size == 0: continue
        try:
            fd = os.open(p, os.O_RDONLY)
            try: addr = libc.mmap(None, st.st_size, PROT_READ, MAP_SHARED, fd, 0)
            finally: os.close(fd)
        except OSError: continue
        if addr in (None, MAP_FAILED): continue
        if libc.mlock(addr, st.st_size) != 0:
            libc.munmap(addr, st.st_size); continue
        pinned[p] = (addr, st.st_size, st.st_mtime)
    for p in list(pinned):
        if p not in seen: _unpin(p)
    stats["files_mb"] = sum(v[1] for v in pinned.values()) / 1e6

def _unpin(p):
    addr, size, _ = pinned.pop(p)
    libc.munlock(addr, size); libc.munmap(addr, size)

def pin_weights(*modules):
    """Lock a torch model's weights where they sit in this process."""
    total = 0
    for m in modules:
        if m is None: continue
        try: tensors = list(m.parameters()) + list(m.buffers())
        except Exception: continue
        for t in tensors:
            try:
                n = t.numel() * t.element_size()
                if n and t.device.type == "cpu" and libc.mlock(ctypes.c_void_p(t.data_ptr()), n) == 0: total += n
            except Exception: pass
    stats["weights_mb"] += total / 1e6
    return total

def start():
    def loop():
        while True:
            try: pin_files()
            except Exception as e: print("keep resident:", repr(e)[:150], flush=True)
            time.sleep(600)                   # the compiled cache can be rebuilt; pick up new files
    threading.Thread(target=loop, daemon=True).start()
