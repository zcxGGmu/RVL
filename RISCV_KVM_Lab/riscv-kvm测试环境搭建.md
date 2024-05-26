# 1 RISC-V环境下的QEMU/KVM虚拟化

## 1.0 问题汇总

* [IPADS-DuVisor/kvm-tutorial (github.com)](https://github.com/IPADS-DuVisor/kvm-tutorial)
* [构建riscv两层qemu的步骤 | Sherlock's blog (wangzhou.github.io)](https://wangzhou.github.io/构建riscv两层qemu的步骤/)
  * [无标题文档 (yuque.com)](https://www.yuque.com/weixin-37430058/klw1dv/mlktwrvemh1t7kvx?singleDoc#)

---

* 执行 `./configure` 错误，编译qemu的riscv64版本缺少相应包：

  [异构软件包的安装问题 · Issue #2 · IPADS-DuVisor/kvm-tutorial (github.com)](https://github.com/IPADS-DuVisor/kvm-tutorial/issues/2)

  ```shell
  sudo apt install gcc-riscv64-linux-gnu pkg-config-riscv64-linux-gnu -y
  sudo apt-get install libpixman-1-dev:riscv64
  sudo apt-get install libglib2.0-dev:riscv64
  ```

* 如果只是简单的把它放进 HOST rootfs 中，任然不能运行，因为这个用 busybox 编译出的简易的 HOST rootfs 没有 RISC-V 的编译环境，即缺少 lib 库等。

  ```shell
  # 请在configure时添加--static选项，以下是我自用的编译指令以供参考：
  ./configure --target-list=riscv64-softmmu --enable-kvm --static \
  --cross-prefix=riscv64-linux-gnu- --disable-libiscsi --disable-glusterfs \
  --disable-libusb --disable-usb-redir --audio-drv-list= --disable-opengl \
   --disable-linux-io-uring
  
  make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j$(nproc)
  ```

* host/guest侧qemu版本不一致导致第二层kvm-guest启动失败：

  >你好，我们使用的是QEMU v7.0.0，没有遇到过这种问题。
  >
  >不知道你在第一层和第二层用到的QEMU版本是否一致，如果不一致则可能是`priv_spec`不匹配，可以尝试通过调整QEMU启动参数`-cpu rv64,priv_spec=v1.11.0`强制对齐`priv_spec`版本。

## 1.1 准备交叉编译工具链

从源码编译： https://github.com/riscv-collab/riscv-gnu-toolchain

从APT安装（Ubuntu 20.04或更新）： `sudo apt-get install crossbuild-essential-riscv64`

```sh
# 依赖
sudo apt-get install autoconf automake autotools-dev curl python3 libmpc-dev libmpfr-dev libgmp-dev gawk build-essential bison flex texinfo gperf libtool patchutils bc zlib1g-dev libexpat-dev

# clone
export WS=`pwd`
git config --global core.compression 0
git config --global http.postBuffer 600000
git clone https://github.com/riscv-collab/riscv-gnu-toolchain.git
cd riscv-gnu-toolchain
git rm qemu
git rm spike
git rm pk
git rm musl
git submodule update --init --recursive --progress

# 配置/编译
cd $WS
mkdir build install && cd build
../riscv-gnu-toolchain/configure --prefix=$WS/install --enable-multilib
make linux -j`nproc`
```

## 1.2 基于RISC-V环境运行Host Linux

### step1: 构建支持H扩展的QEMU

> 这一步是用qemu模拟一个支持H扩展的RISC-V硬件平台

* 安装依赖：https://wiki.qemu.org/Hosts/Linux

  ```shell
  sudo apt-get install git libglib2.0-dev libfdt-dev libpixman-1-dev zlib1g-dev ninja-build gcc-riscv64-linux-gnu pkg-config-riscv64-linux-gnu
  ```

* 从源码编译QEMU，版本在7.0及以上：

  ```shell
  git clone https://gitlab.com/qemu-project/qemu.git rv-emul-qemu
  cd rv-emul-qemu
  git submodule init
  git submodule update --recursive
  ./configure --target-list="riscv32-softmmu riscv64-softmmu" --cross-prefix=riscv64-linux-gnu-
  make
  cd ..
  ```

  在 `./configure` 这步根据每个人主机环境不同，可能还需要主机环境中有一系列RISCV64架构的基础库，建议参考链接 https://wiki.debian.org/Multiarch/HOWTO。配置成功后应当可以成功进行如下安装:

  ```shell
  sudo apt-get install libpixman-1-dev:riscv64
  sudo apt-get install libglib2.0-dev:riscv64
  ```

### step2: 构建Host Linux

> 在step1搭建好的模拟RISC-V平台上，构建Linux作为宿主机操作系统。

Linux版本需要5.16或更新，config可自行调整，需保证CONFIG_KVM开启：

```shell
sudo apt install autoconf automake autotools-dev curl libmpc-dev libmpfr-dev libgmp-dev \
                 gawk build-essential bison flex texinfo gperf libtool patchutils bc \
                 zlib1g-dev libexpat-dev git \
                 libglib2.0-dev libfdt-dev libpixman-1-dev \
                 libncurses5-dev libncursesw5-dev

git clone https://github.com/kvm-riscv/linux.git
export ARCH=riscv
export CROSS_COMPILE=riscv64-unknown-linux-gnu-
mkdir build-hosts
make -C linux O=`pwd`/build-host defconfig
make -C linux O=`pwd`/build-host
```

### step3: 构建Host RootFS

生成`rootfs_kvm_host.img`：

```shell
export ARCH=riscv
export CROSS_COMPILE=riscv64-unknown-linux-gnu-
git clone https://github.com/kvm-riscv/howto.git
wget https://busybox.net/downloads/busybox-1.33.1.tar.bz2
tar -C . -xvf ./busybox-1.33.1.tar.bz2
mv ./busybox-1.33.1 ./busybox-1.33.1-kvm-host
cp -f ./howto/configs/busybox-1.33.1_defconfig busybox-1.33.1-kvm-host/.config
make -C busybox-1.33.1-kvm-host oldconfig
make -C busybox-1.33.1-kvm-host install
mkdir -p busybox-1.33.1-kvm-host/_install/etc/init.d
mkdir -p busybox-1.33.1-kvm-host/_install/dev
mkdir -p busybox-1.33.1-kvm-host/_install/proc
mkdir -p busybox-1.33.1-kvm-host/_install/sys
mkdir -p busybox-1.33.1-kvm-host/_install/apps
ln -sf /sbin/init busybox-1.33.1-kvm-host/_install/init
cp -f ./howto/configs/busybox/fstab busybox-1.33.1-kvm-host/_install/etc/fstab
cp -f ./howto/configs/busybox/rcS busybox-1.33.1-kvm-host/_install/etc/init.d/rcS
cp -f ./howto/configs/busybox/motd busybox-1.33.1-kvm-host/_install/etc/motd
cp -f ./build-host/arch/riscv/kvm/kvm.ko busybox-1.33.1-kvm-host/_install/apps
cd busybox-1.33.1-kvm-host/_install; find ./ | cpio -o -H newc >  ../../rootfs_kvm_host.img; cd -
```

### step4: 基于QEMU运行Host Linux

使用之前构建好的宿主机内核镜像和根文件系统，启动Host Linux：

```shell
./rv-emul-qemu/build/qemu-system-riscv64 \
    -cpu rv64 \
    -M virt \
    -m 1024M \
    -nographic \
    -kernel ./build-host/arch/riscv/boot/Image \
    -initrd ./rootfs_kvm_host.img \
    -append "root=/dev/ram rw console=ttyS0 earlycon=sbi"
```

启动后验证Host Linux的KVM是否使能成功：

```shell
           _  _
          | ||_|
          | | _ ____  _   _  _  _ 
          | || |  _ \| | | |\ \/ /
          | || | | | | |_| |/    \
          |_||_|_| |_|\____|\_/\_/

               Busybox Rootfs

Please press Enter to activate this console. 
/ # 
/ # cat /proc/cpuinfo 
processor	: 0
hart		: 0
isa		: rv64imafdcsuh
mmu		: sv48

/ # cat /proc/interrupts 
           CPU0       
  1:          0  SiFive PLIC  11  101000.rtc
  2:        153  SiFive PLIC  10  ttyS0
  5:        449  RISC-V INTC   5  riscv-timer
IPI0:         0  Rescheduling interrupts
IPI1:         0  Function call interrupts
IPI2:         0  CPU stop interrupts

/ # insmod apps/kvm.ko
/ # dmesg | grep kvm
[    1.094977] kvm [1]: hypervisor extension available
[    1.096555] kvm [1]: host has 14 VMID bits
[   20.254215] random: fast init done
```

## 1.3 使用KVM运行Guest Linux

### step1: 构建Guest Linux

Linux版本与config可自行调整，如需使用I/O则开启CONFIG_VIRTIO相关选项：

```shell
git clone https://github.com/kvm-riscv/linux.git
export ARCH=riscv
export CROSS_COMPILE=riscv64-unknown-linux-gnu-
mkdir build-guest
make -C linux O=`pwd`/build-guest defconfig
make -C linux O=`pwd`/build-guest
```

### //issue step2: 构建用于KVM的QEMU

> **原文档的这步是错误的，此处的qemu是需要在RISC-V环境中运行的，因此存在两个必须解决的问题：**
>
> * 在本地交叉编译qemu的riscv64版本，这涉及到qemu编译时所依赖包的riscv64版本如何下载的问题；
> * 采用 `-static` 静态链接的方式，因为在Host-RV64的qemu模拟环境中并没有qemu的运行环境（缺少动态库）；

```shell
git clone https://gitlab.com/qemu-project/qemu.git kvm-qemu
cd kvm-qemu
git submodule init
git submodule update --recursive
export ARCH=riscv
export CROSS_COMPILE=riscv64-linux-gnu- 
./configure --target-list="riscv32-softmmu riscv64-softmmu"
make
cd ..
```

### step3: 构建Guest RootFS

生成 `rootfs_kvm_guest.img`：

```sh
export ARCH=riscv
export CROSS_COMPILE=riscv64-unknown-linux-gnu-
tar -C . -xvf ./busybox-1.33.1.tar.bz2
mv ./busybox-1.33.1 ./busybox-1.33.1-kvm-guest
cp -f ./howto/configs/busybox-1.33.1_defconfig busybox-1.33.1-kvm-guest/.config
make -C busybox-1.33.1-kvm-guest oldconfig
make -C busybox-1.33.1-kvm-guest install
mkdir -p busybox-1.33.1-kvm-guest/_install/etc/init.d
mkdir -p busybox-1.33.1-kvm-guest/_install/dev
mkdir -p busybox-1.33.1-kvm-guest/_install/proc
mkdir -p busybox-1.33.1-kvm-guest/_install/sys
mkdir -p busybox-1.33.1-kvm-guest/_install/apps
ln -sf /sbin/init busybox-1.33.1-kvm-guest/_install/init
cp -f ./howto/configs/busybox/fstab busybox-1.33.1-kvm-guest/_install/etc/fstab
cp -f ./howto/configs/busybox/rcS busybox-1.33.1-kvm-guest/_install/etc/init.d/rcS
cp -f ./howto/configs/busybox/motd busybox-1.33.1-kvm-guest/_install/etc/motd
cd busybox-1.33.1-kvm-guest/_install; find ./ | cpio -o -H newc > ../../rootfs_kvm_guest.img; cd -
```

### step4: 将Guest Linux需要的QEMU与RootFS镜像放入Host RootFS

重新生成 `rootfs_kvm_host.img`：

```sh
cp -f ./build-guest/arch/riscv/boot/Image busybox-1.33.1-kvm-host/_install/apps
cp -f ./kvm-qemu/build/qemu-system-riscv64 busybox-1.33.1-kvm-host/_install/apps
cp -f ./rootfs_kvm_guest.img busybox-1.33.1-kvm-host/_install/apps
cp -f ./start_guest_linux.sh busybox-1.33.1-kvm-host/_install/apps
cd busybox-1.33.1-kvm-host/_install; find ./ | cpio -o -H newc > ../../rootfs_kvm_host.img; cd -
```

### step5: 使用新Host Rootfs运行Host Linux

```sh
./rv-emul-qemu/build/qemu-system-riscv64 \
    -cpu rv64 \
    -M virt \
    -m 1024M \
    -nographic \
    -kernel ./build-host/arch/riscv/boot/Image \
    -initrd ./rootfs_kvm_host.img \
    -append "root=/dev/ram rw console=ttyS0 earlycon=sbi"
```

### step6: 基于KVM运行Guest Linux

> 注意这里相较于启动Host Linux的命令多了 `--enable-kvm` 选项，意味着Guest Linux将使用Host Linux提供的KVM模块进行加速，该KVM依赖的硬件是用qemu模拟的使能了H扩展的RISC-V平台。

```shell
./qemu-system-riscv64 \
    -cpu host \
    --enable-kvm \
    -M virt \
    -m 512M \
    -nographic \
    -kernel ./Image \
    -initrd ./rootfs_kvm_guest.img \
    -append "root=/dev/ram rw console=ttyS0 earlycon=sbi"

./qemu-system-riscv64 -cpu host --enable-kvm -M virt -m 512M -nographic -kernel ./Image
-initrd ./rootfs_kvm_guest.img -append "root=/dev/ram rw console=ttyS0 earlycon=sbi"
```



## 1.4 第二层qemu的另一种构建方式

### 引用

[构建riscv两层qemu的步骤 | Sherlock's blog (wangzhou.github.io)](https://wangzhou.github.io/构建riscv两层qemu的步骤/)

[无标题文档 (yuque.com)](https://www.yuque.com/weixin-37430058/klw1dv/mlktwrvemh1t7kvx?singleDoc#)

### 第二层qemu构建流程

> 第一层qemu搭建流程参照 `1.2`。

第二层qemu的编译比较有意思，因为qemu编译需要依赖很多动态库，想得到一个riscv64版本的qemu需要先交叉编译qemu依赖的动态库，然后再交叉编译qemu，太麻烦了。我们这里用编译buildroot的方式一同编译小文件系统里的qemu, buildroot编译qemu的时候就会一同编译qemu依赖的各种库, 这样编译出的host文件系统里就带了qemu。

#### 下载buildroot工具

```shell
git clone https://github.com/buildroot/buildroot.git
cd buildroot
make menuconfig
```

#### 选择riscv架构

> **Target options  --->  Target Architecture （i386）--->  (x) RISCV**

![img](https://cdn.nlark.com/yuque/0/2023/png/38811017/1693545081802-a8336959-3c4d-46c9-9485-ac9367b93650.png)

#### 选择ext文件系统

> **Filesystem images ---> [*] ext2/3/4 root filesystem**

![img](https://cdn.nlark.com/yuque/0/2023/png/38811017/1693545241748-98ded40b-c1e5-446f-bb30-75d96085ee02.png)

下方的exact size可以调整ext文件系统大小配置，默认为60M，这里需要调整到500M以上，因为需要编译qemu文件进去。

#### buildroot配置qemu

```shell
BR2_TOOLCHAIN_BUILDROOT_GLIBC=y/
BR2_USE_WCHAR=y
BR2_PACKAGE_QEMU=y/
BR2_TARGET_ROOTFS_CPIO=y
BR2_TARGET_ROOTFS_CPIO_GZIP=y

 Prompt: gzip                                                                                                                                 │  
  │   Location:                                                                                                                                  │  
  │     -> Filesystem images                                                                                                                     │  
  │       -> cpio the root filesystem (for use as an initial RAM filesystem) (BR2_TARGET_ROOTFS_CPIO [=y])                                       │  
  │ (1)     -> Compression method (<choice> [=y])  
```

在可视化页面按 `/` 即可进入搜索模式，在搜索模式分别输入上述参数：

<img src="https://cdn.nlark.com/yuque/0/2023/png/38811108/1695365777988-0ddae6e1-cc5a-40b0-841a-6caf5bc69529.png" alt="img" style="zoom: 33%;" />

<img src="https://cdn.nlark.com/yuque/0/2023/png/38811108/1695365865223-acf0d8f9-25ee-4451-9549-090eaa7de25f.png" alt="img" style="zoom: 33%;" />

#### 全部开启后保存退出 -> 编译

`make -j$(nproc)` 编译，完成后在 `output/images` 目录下得到rootfs.ext2，将它复制到工作目录。

两层qemu的版本需保持一致，因为不同版本的qemu模拟的riscv平台 `priv-spec` 可能不同，我用的是 `8.1.0`：

```sh
# qemu-system-riscv64 --version
QEMU emulator version 8.1.0
Copyright (c) 2003-2023 Fabrice Bellard and the QEMU Project developers
```

### host-kvm启动第二层qemu

注意，第二层qemu运行的内核就使用第一层qemu对应的内核即可。随后，从主机运行脚本：

`strat_qemu_1.sh`

```sh
#!/bin/bash

sudo /home/wx/QEMU/qemu/build/qemu-system-riscv64 \
-M virt \
-cpu 'rv64,h=true' \
-m 2G \
-kernel Image \
-append "rootwait root=/dev/vda ro" \
-drive file=rootfs.ext2,format=raw,id=hd0 \
-device virtio-blk-device,drive=hd0 \
-nographic \
-virtfs local,path=/home/wx/Documents/shared,mount_tag=host0,security_model=passthrough,id=host0 \
-netdev user,id=net0 -device virtio-net-device,netdev=net0
```

在RISC-V模拟平台（host-kvm）上运行 `start_qemu_2.sh`：

```sh
#!/bin/sh

/usr/bin/qemu-system-riscv64 \
-M virt --enable-kvm \
-cpu rv64 \
-m 256m  \
-kernel ./Image \
-append "rootwait root=/dev/vda ro" \
-drive file=rootfs.ext2,format=raw,id=hd0 \
-device virtio-blk-device,drive=hd0 \
-nographic 
```

# 2 用QEMU/Spike+KVM运行RV-Host/Guest Linux

[用 QEMU/Spike+KVM 运行 RISC-V Host/Guest Linux - 泰晓科技 (tinylab.org)](https://tinylab.org/riscv-kvm-qemu-spike-linux-usage/)

## 2.0 问题汇总





## 2.1 实验背景

本文基于 QEMU 和 Spike 模拟器，搭建了基于H扩展的RISC-V硬件平台并引导 Host Linux 操作系统（支持RISC-V KVM），并在Host Linux上利用KVM加速以运行 Guest Linux。

整体软件栈如下：

![kvm](https://tinylab.org/wp-content/uploads/2022/03/riscv-linux/images/20220708-kvm-linux/kvm-hypervisor.png)

所有软件构建结果如下表所示：

| Item                             | Products                                                     |
| :------------------------------- | :----------------------------------------------------------- |
| QEMU(Simulator)                  | `./qemu/build/qemu-system-riscv64`                           |
| Spike(Simulator)                 | ./riscv-isa-sim/spike                                        |
| **Firmware**(OpenSBI)            | `./opensbi/build/platform/generic/firmware/fw_jump.bin` (`fw_jump.elf`) |
| **Kernel Image**                 | `build-riscv64/arch/riscv/boot/Image`; `build-riscv64/arch/riscv/kvm/kvm.ko` |
| userspace **kvmtool**            | `./kvmtool/lkvm-static`                                      |
| **RootFS**(use Busybox to build) | `./rootfs_kvm_riscv64.img`                                   |

## 2.2 实验流程

### 基础环境准备

首先准备一台虚拟机或裸机ubuntu22.04，或基于 Docker container 的基础实验环境：

```sh
# download image if it doesnot exist, create container kvm based on this image and start it interactively
docker run -it --name kvm ubuntu:20.04 /bin/bash
# install necessary toolchain and dependency (if the below is not enough, feel free to install what you want)
root@0152fed4b28d:~# apt install gcc g++ gcc-riscv64-linux-gnu wget flex bison bc cpio make pkg-config
```

### 组件下载与编译

#### QEMU模拟器

首先，安装编译所需的依赖：

```sh
sudo apt install git libglib2.0-dev libfdt-dev libpixman-1-dev zlib1g-dev libncurses-dev libssl-dev ninja-build
```

从 GitLab 下载 qemu，这将拉取最新版本的qemu代码，或者选择指定版本的qemu压缩包 [blfs-conglomeration-qemu安装包下载_开源镜像站-阿里云 (aliyun.com)](https://mirrors.aliyun.com/blfs/conglomeration/qemu/)：

```sh
git clone https://gitlab.com/qemu-project/qemu.git
cd qemu
git submodule init
git submodule update --recursive
```

指定支持的 ISA 并编译：

```sh
./configure --target-list="riscv32-softmmu riscv64-softmmu" && make -j`nproc`
```

编译后生成的文件在：`./qemu/build/qemu-system-riscv64`。

#### Spike模拟器

```sh
sudo apt install device-tree-compiler
git clone https://github.com/riscv-software-src/riscv-isa-sim && cd riscv-isa-sim
./configure
make
# ./riscv-isa-sim/spike will be the built Spike simulator in later use
```

#### OpenSBI固件

```sh
git clone https://github.com/riscv/opensbi.git
cd opensbi
export ARCH=riscv
export CROSS_COMPILE=riscv64-linux-gnu-
make PLATFORM=generic  -j`nproc`
# ./opensbi/build/platform/generic/firmware/fw_jump.bin as M-mode runtime firmware
```

#### Linux内核

下载内核源码：

```sh
# the mirror of the newest kernel version in kvm-riscv howto
git clone https://github.com/kvm-riscv/linux.git 
```

接着，创建编译目录并配置**处理器架构和交叉编译器**等环境变量：

```sh
export ARCH=riscv
export CROSS_COMPILE=riscv64-linux-gnu-
mkdir build-riscv64
```

接着，通过 menuconfig 配置内核选项。在配置之前，需要注意最新版 Linux 内核默认关闭 RISC-V SBI 相关选项，需要通过以下命令手动配置开启，具体细节参见 [此文](https://zhuanlan.zhihu.com/p/539390400)。

```sh
# change options of kernel compiling to generate build-riscv64/.config (output dir)
make -C linux O=`pwd`/build-riscv64 menuconfig 
```

最后编译：

```sh
make -C linux O=`pwd`/build-riscv64  -j`nproc`
```

编译完成后，将得到两个二进制文件：

- 内核映像：`build-riscv64/arch/riscv/boot/Image`
- KVM 内核模块：`build-riscv64/arch/riscv/kvm/kvm.ko`

#### kvmtool工具

> 这里的kvmtool是一个轻量级的kvm虚拟机管理工具，等价于第1章中的第二层qemu。 注意对齐 `dtc/kvmtool` 的版本，kvmtool编译运行的过程中，依赖dtc所提供的头文件和库，注意使用 `sudo make` 。
>
> 此处的commit_id：
>
> ```markdown
> dtc https://git.kernel.org/pub/scm/utils/dtc/dtc.git
> commit ccf1f62d59adc933fb348b866f351824cdd00c73 (HEAD -> master, origin/master, origin/main, origin/HEAD)
> 
> Author: Yan-Jie Wang <yanjiewtw@gmail.com>
> Date:   Thu Jun 8 14:39:05 2023 +0800
> 
> 
> kvmtool https://git.kernel.org/pub/scm/linux/kernel/git/will/kvmtool.git
> 
> commit 0b5e55fc032d1c6394b8ec7fe02d842813c903df (HEAD -> master, origin/master, origin/HEAD)
> 
> Author: Jean-Philippe Brucker <jean-philippe@linaro.org>
> Date:   Wed Jun 28 12:23:32 2023 +0100
> ```

首先，需要准备好 libfdt 库，将其添加到工具链所在位置的 `sysroot` 文件夹中：

```sh
# install cross-compiled libfdt library at $SYSROOT/usr/lib64/lp64d directory of cross-compile toolchain
git clone git://git.kernel.org/pub/scm/utils/dtc/dtc.git
cd dtc
export ARCH=riscv
export CROSS_COMPILE=riscv64-linux-gnu-
export CC="${CROSS_COMPILE}gcc -mabi=lp64d -march=rv64gc" # riscv toolchain should be configured with --enable-multilib to support the most common -march/-mabi options if you build it from source code
TRIPLET=$($CC -dumpmachine)
SYSROOT=$($CC -print-sysroot)
sudo make libfdt  -j`nproc`
sudo make NO_PYTHON=1 NO_YAML=1 DESTDIR=$SYSROOT PREFIX=/usr LIBDIR=/usr/lib64/lp64d install-lib install-includes  -j`nproc`
cd ..
```

接着，编译 kvmtools：

```sh
git clone https://git.kernel.org/pub/scm/linux/kernel/git/will/kvmtool.git
cd kvmtool
export ARCH=riscv
export CROSS_COMPILE=riscv64-linux-gnu-
sudo make lkvm-static  -j`nproc`
${CROSS_COMPILE}strip lkvm-static
cd ..
```

#### RootFS文件系统

RootFS 包括 `KVM kernel module`, `userspace kvmtools`, `kernel image` 三部分。

```sh
export ARCH=riscv
export CROSS_COMPILE=riscv64-linux-gnu-
git clone https://github.com/kvm-riscv/howto.git
wget https://busybox.net/downloads/busybox-1.33.1.tar.bz2
tar -C . -xvf ./busybox-1.33.1.tar.bz2
mv ./busybox-1.33.1 ./busybox-1.33.1-kvm-riscv64
cp -f ./howto/configs/busybox-1.33.1_defconfig busybox-1.33.1-kvm-riscv64/.config
make -C busybox-1.33.1-kvm-riscv64 oldconfig
make -C busybox-1.33.1-kvm-riscv64 install
mkdir -p busybox-1.33.1-kvm-riscv64/_install/etc/init.d
mkdir -p busybox-1.33.1-kvm-riscv64/_install/dev
mkdir -p busybox-1.33.1-kvm-riscv64/_install/proc
mkdir -p busybox-1.33.1-kvm-riscv64/_install/sys
mkdir -p busybox-1.33.1-kvm-riscv64/_install/apps
ln -sf /sbin/init busybox-1.33.1-kvm-riscv64/_install/init
cp -f ./howto/configs/busybox/fstab busybox-1.33.1-kvm-riscv64/_install/etc/fstab
cp -f ./howto/configs/busybox/rcS busybox-1.33.1-kvm-riscv64/_install/etc/init.d/rcS
cp -f ./howto/configs/busybox/motd busybox-1.33.1-kvm-riscv64/_install/etc/motd
cp -f ./kvmtool/lkvm-static busybox-1.33.1-kvm-riscv64/_install/apps
cp -f ./build-riscv64/arch/riscv/boot/Image busybox-1.33.1-kvm-riscv64/_install/apps
cp -f ./build-riscv64/arch/riscv/kvm/kvm.ko busybox-1.33.1-kvm-riscv64/_install/apps
cd busybox-1.33.1-kvm-riscv64/_install; find ./ | cpio -o -H newc > ../../rootfs_kvm_riscv64.img; cd -
```

### QEMU+KVM方案

#### 启动Host Linux

qemu模拟RISC-V平台并启动Host Linux：

```sh
./qemu/build/qemu-system-riscv64 -cpu rv64 -M virt -m 512M -nographic \
  -bios opensbi/build/platform/generic/firmware/fw_jump.bin \
  -kernel ./build-riscv64/arch/riscv/boot/Image \
  -initrd ./rootfs_kvm_riscv64.img
  -append "root=/dev/ram rw console=ttyS0 earlycon=sbi"
```

注意，在上一步中，如果 initrd 未使用 RISC-V 工具链编译，可能会出现如下问题：

```sh
[ 0.629637] ---[ end Kernel panic - not syncing: No working init found. Try passing init= option to kernel. See Linux Documentation/admin-guide/init.rst for guidance. ]---
```

#### 启动Guest Linux

在上一步打开的Host Linux仿真环境中执行以下步骤：

* 首先，加入KVM内核模块：

  ```sh
  cd ./apps
  
  insmod kvm.ko
  ```

* 接着 kvmtool 运行 Guest Linux：

  ```sh
  ./lkvm-static run -m 128 -c2 --console serial -p "console=ttyS0 earlycon" -k ./Image --debug
  ```

### Spike+KVM方案

#### 启动Host Linux

spike模拟RISC-V平台并启动Host Linux：

```sh
# Run Host Linux
./riscv-isa-sim/spike -m512 --isa rv64gch --kernel ./build-riscv64/arch/riscv/boot/Image --initrd ./rootfs_kvm_riscv64.img opensbi/build/platform/generic/firmware/fw_jump.elf
```

#### 启动Guest Linux

```sh
# insert kvm kernel module
insmod apps/kvm.ko

# start guest os using lkvm-static
./apps/lkvm-static run -m 128 -c2 --console serial -p "console=ttyS0 earlycon=uart8250,mmio,0x3f8" -k ./apps/Image --debug
```

# 3 kvm-riscv-patch验证环境

## 3.1 KVM Selftests/kvm unit test验证

[[PATCH v4 00/11\] RISCV: Add kvm Sstc timer selftests - Haibo Xu (kernel.org)](https://lore.kernel.org/all/cover.1702371136.git.haibo1.xu@intel.com/)

```sh
 Info: # lkvm run -k ./apps/Image -m 128 -c 1 --name guest-49
  Debug: (riscv/kvm.c) kvm__arch_load_kernel_image:136: Loaded kernel to 0x80200000 (22056960 bytes)
  Debug: (riscv/kvm.c) kvm__arch_load_kernel_image:147: Placing fdt at 0x81c00000 - 0x87ffffff
```

![703c6daa8332fc068fd2361cba8d2bf](C:/Users/26896/Documents/WeChat%20Files/wxid_hx5cs9g1pyo22/FileStorage/Temp/703c6daa8332fc068fd2361cba8d2bf.png)

```sh
Host tiaoban
    HostName isrc.iscas.ac.cn 
    Port 5022
     User USERNAME 
Host server 
    HostName SERVER_IP 
    Port 22 
    User SERVER_USERNAME 
    ProxyCommand ssh tiaoban -W %h:%p
    
192.168.16.208
zhouquan
ISRCpassword123

Host jump
    HostName isrc.iscas.ac.cn 
    User username
    Port 5022
    ForwardAgent yes
Host target
    HostName SERVER_IP
    User SERVER_USERNAME 
    Port 22
    ProxyJump jump
```



## 3.2 KVM feature验证

### sstc

[[PATCH v7 0/4\] Add Sstc extension support - Atish Patra (kernel.org)](https://lore.kernel.org/all/20220722165047.519994-1-atishp@rivosinc.com/)

```c
 make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu -C linux/tools/testing/selftests TARGETS=kvm O=build-selftests

执行以上命令，报错信息如下：
/usr/include/linux/kvm.h:15:10: fatal error: asm/kvm.h: No such file or directory
   15 | #include <asm/kvm.h>
      |          ^~~~~~~~~~~
compilation terminated.

什么原因？如何解决？
```







### pmu





















