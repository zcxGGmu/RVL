PREFIX=/home/zq/objs/repo/patch-work/toolchain-repo/riscv/riscv-4.12/bin/riscv64-unknown-linux-gnu-
CC=$(PREFIX)gcc
CFLAGS+=-Wall -static
SRC=src
GUEST=$(SRC)/guest
KVMTOOL=$(SRC)/kvm-tools

app:
	$(PREFIX)gcc -mcmodel=medany -nostartfiles $(GUEST)/main.c -c -o output/main.o
	$(PREFIX)gcc -mcmodel=medany -nostartfiles $(GUEST)/entry.S -c -o output/entry.o
	$(PREFIX)ld -T $(GUEST)/app.lds output/main.o output/entry.o -o output/app
	$(PREFIX)objcopy -O binary --strip-all output/app output/app.bin

kvm: 
	$(PREFIX)gcc -static $(KVMTOOL)/kvm.c -o output/kvm

img: kvm app
	cp output/kvm _install/apps
	cp output/app.bin _install/apps
	cd _install; find ./ | cpio -o -H newc > ../output/rootfs_kvm_riscv64.img; cd -

run: img
	/home/zq/objs/repo/patch-work/build-qemu/riscv/qemu-system-riscv64 \
		-cpu rv64 -M virt -m 512M -nographic \
		-kernel output/Image \
		-initrd output/rootfs_kvm_riscv64.img \
		-append "root=/dev/ram rw console=ttyS0 earlycon=sbi"
