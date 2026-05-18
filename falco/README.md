# Falco Artifacts

Drop your Falco build artifacts here. `build_base.sh` sẽ tự động detect và include vào initramfs.

## Cấu trúc

```
falco/
├── bin/
│   └── falco          ← Falco binary (drop here)
├── libs/
│   └── *.so*          ← Shared libs (tùy chọn, auto-detect qua ldd nếu để trống)
└── rules/
    └── falco_rules.yaml   ← Rules để detect events trong VM
```

## Cách lấy Falco binary

### Option 1 — Tải prebuilt từ Falco releases:
```bash
VERSION=0.38.0
wget https://github.com/falcosecurity/falco/releases/download/${VERSION}/falco-${VERSION}-x86_64.tar.gz
tar xzf falco-*.tar.gz
cp falco-*/usr/bin/falco falco/bin/falco
```

### Option 2 — Nếu đã install trên host:
```bash
cp /usr/bin/falco falco/bin/falco
```

Sau khi drop binary vào, rebuild base image:
```bash
rm -f initramfs-base.img
bash builder/build_base.sh
```

## Falco probe modules

Probe được compile cho từng kernel phải đặt tại:
```
modules/<distro>-<version>-<kernel_version>/
├── falco_probe.ko    ← kernel module (dùng cho kmod engine)
└── falco-probe.o     ← eBPF probe (dùng cho ebpf engine, kernel >= 4.14)
```

Tải prebuilt probe tại: https://download.falco.org/driver/<falco-version>/
