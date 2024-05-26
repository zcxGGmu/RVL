# 1 kvm-unit-tests文档

The source code can be found at:

- https://gitlab.com/kvm-unit-tests/kvm-unit-tests.git

## 1.1 Introduction

`kvm-unit-tests` 是一个与 KVM 同龄的项目。正如其名称所示，它的目的是为 KVM 提供[单元测试](http://en.wikipedia.org/wiki/Unit_testing)。单元测试是极小的客户操作系统，通常只执行几十行的 C 和汇编测试代码，以获取其通过/失败的结果。通过针对硬件规范的最小实现来测试目标功能，单元测试为 KVM 和虚拟硬件提供功能测试。单元测试的简单性使它们易于验证是否正确，易于维护，并且易于在时间测量中使用。单元测试也经常用于快速和简单的缺陷重现。然后，这些重现可能被保留作为回归测试。强烈鼓励提交实现新 KVM 功能的补丁时，附带相应的单元测试。

**虽然单个单元测试集中于单一功能，但所有单元测试都共享最小的系统初始化和设置代码。**还有几个函数可在所有单元测试中共享，构成了单元测试 API。下一节["框架"](https://www.linux-kvm.org/page/KVM-unit-tests#Framework)简要描述了设置代码和 API 实现。然后我们在["Testdevs"](https://www.linux-kvm.org/page/KVM-unit-tests#Testdevs)一节中描述了测试设备，这是对 KVM 用户空间的扩展，为单元测试提供特殊支持。["API"](https://www.linux-kvm.org/page/KVM-unit-tests#API)一节列出了 API 覆盖的子系统，例如 MMU、SMP，以及 API 支持的一些描述。它特意避免列出任何实际的函数声明，因为这些可能会改变（使用源代码，卢克！）。["运行测试"](https://www.linux-kvm.org/page/KVM-unit-tests#Running_tests)一节提供了构建和运行测试所需的所有细节，而["添加测试"](https://www.linux-kvm.org/page/KVM-unit-tests#Adding_a_test)一节提供了添加测试的示例。最后，["贡献"](https://www.linux-kvm.org/page/KVM-unit-tests#Contributing)一节解释了在哪里以及如何提交补丁。

## 1.2 Framework

`kvm-unit-tests` 框架支持多种架构，目前包括 i386、x86_64、armv7（arm）、armv8（arm64）、ppc64、ppc64le 和 s390x。通过采用 Linux 的配置 asm 符号链接，该框架使在类似架构之间共享代码变得更容易。通过 asm 符号链接，每个架构都有自己的头文件副本，但可以选择共享相同的代码。

框架包括以下组件：

- **测试构建支持 — Test building support**

  测试构建是通过 makefiles 和一些支持的 bash 脚本完成的。

- **用于测试设置和 API 的共享代码 — Shared code for test setup and API**

  测试设置代码包括，例如，早期系统初始化、MMU 启用和 UART 初始化。API 提供了一些常见的 libc 函数，例如 strcpy、atol、malloc、printf，以及一些常见于内核代码的低级helper，例如 `irq_enable/disable`、`virt_to_phys/phys_to_virt`，以及一些特定于 `kvm-unit-tests` 的 API，例如，安装异常处理程序和报告测试成功/失败。

- **测试运行支持 — Test running support**

  测试运行通过一些 bash 脚本提供，使用单元测试配置文件作为输入。通常在源根目录内部使用支持脚本运行测试，但也可以选择将测试构建为独立测试。有关独立构建和运行的更多信息，请参阅["运行测试"](https://www.linux-kvm.org/page/KVM-unit-tests#Running_tests)一节。

## 1.3 Testdevs

像所有客户机一样，`kvm-unit-test` 单元测试（一个迷你客户机）不仅与 KVM 一起运行，还与 KVM 的用户空间一起运行。单元测试能够打开一个与 KVM 用户空间特定的通信通道是很有用的，**它允许单元测试发送命令以控制主机行为或触发客户机外部事件。**特别是，通道对于启动退出非常有用，即退出单元测试。`Testdevs` 填补了这些角色。以下是目前在 QEMU 中的 `testdevs`：

- `isa-debug-exit`
  一个 x86 设备，打开一个 I/O 端口。当写入 I/O 端口时，它会引发一个退出，使用写入的值形成退出代码。注意，写入的退出代码会被修改为 `(code << 1) | 1`。因此，一个成功退出的单元测试会引起 QEMU 以 1 退出。

- `pc-testdev`
  一个 x86 设备，打开几个 I/O 端口，每个端口提供一个单元测试辅助功能的接口。其中一个功能是中断注入。

- `pci-testdev`
  一个 PCI “设备”，读写时测试 PCI 访问。

- `edu`
  一个 PCI 设备，支持测试 INTx 和 MSI 中断以及 DMA 传输。

- `testdev`
  一个与架构无关的 `testdev`，通过串行通道以后缀表示法接收命令。单元测试在其单元测试客户机配置中添加一个额外的串行通道（第一个用于测试输出），然后将此设备绑定到它。`kvm-unit-tests` 对 virtio 的支持很少，以允许额外的串行通道是 virtio-serial 的一个实例。目前 `testdev` 只支持命令 "codeq"，其工作方式与 `isa-debug-exit` testdev 完全相同。

## 1.4 API

`kvm-unit-tests` 中有三类 API：1) libc，2) 典型的内核代码功能，和 3) 特定于 kvm-unit-tests 的功能。实现的 libc 很少，但一些最常用的功能，如 strcpy、memset、malloc、printf、assert、exit 等都是可用的。为了概述（2），最好按子系统分解它们：

* **Device discovery**
  * ACPI - 最小的表格搜索支持。目前仅限 x86。
  * 设备树 - libfdt 和一个包装 libfdt 的设备树库，以适应符合 Linux 文档的设备树的使用。例如，有一个函数可以从 /chosen 获取 "bootargs"，然后在单元测试开始之前，通过设置代码将这些参数输入到单元测试的主函数的输入（argc, argv）中。

* **Vectors**
  * 安装异常处理程序的功能。

* **Memory**
  * 内存分配的功能。在单元测试开始之前，系统初始化期间为分配准备的空闲内存。
  * MMU 启用/禁用、TLB 刷新、PTE 设置等功能。

* **SMP**
  * 启动次级处理器、迭代在线 CPU 等功能。
  * 屏障、自旋锁、原子操作、cpumasks 等。

* **I/O**
  * 向 UART 输出消息。在单元测试开始之前，系统初始化期间会初始化 UART。
  * 读写 MMIO 的功能。
  * 读写 I/O 端口的功能（仅限 x86）。
  * 访问 PCI 设备的功能。

* **Power management**
  * PSCI（仅限 arm/arm64）。
  * RTAS（仅限 PowerPC）。

* **Interrupt controller**
  * 启用/禁用、发送 IPI 等功能。
  * 启用/禁用 IRQ 的功能。

* **Virtio**
  * 缓冲区发送支持。目前仅限 virtio-mmio。

* **Misc (杂项)**
  * 特殊寄存器访问器。
  * 切换到用户模式支持。
  * Linux 的 asm-offsets 生成，可用于需要从汇编访问的结构。

注意，实现上述功能的许多函数名称是特定于 `kvm-unit-tests` 的，使它们也成为特定于 `kvm-unit-tests` 的 API 的一部分。然而，至少对于 arm/arm64，任何实现 Linux 内核已有功能的函数，我们都使用相同的名称（如果可能，确切相同的类型签名）。特定于 `kvm-unit-tests` 的 API 还包括一些特定于测试的功能，如 `report()` 和 `report_summary()` 。`report*` 函数应用于报告测试的通过/失败结果，以及整体测试结果概要。

## 1.5 Running tests

以下是构建和运行测试的一些示例：

> **在当前主机上运行所有测试**

```sh
git clone https://gitlab.com/kvm-unit-tests/kvm-unit-tests.git
cd kvm-unit-tests/
./configure
make
./run_tests.sh
```
> **交叉编译并使用特定的 QEMU 运行**

```
./configure --arch=arm64 --cross-prefix=aarch64-linux-gnu-
make
export QEMU=/path/to/qemu-system-aarch64
./run_tests.sh
```
> **并行构建和运行**

```sh
./configure
make -j`nproc`
./run_tests.sh -j 4 # 同时运行最多四个单元测试
```
> **运行单个测试，传递额外的 QEMU 命令行选项**

```sh
./arm-run arm/selftest.flat -smp 4 -append smp
```
* `Note1`

  run_tests.sh 运行 $TEST_DIR/unittests.cfg 中的每个测试（TEST_DIR 以及一些其他变量，在运行 configure 后在 config.mak 中定义。参见 './configure -h' 获取支持的选项列表。）

* `Note2`

  当单独运行单元测试时，所有输出都输出到 stdout。当通过 run_tests.sh 运行单元测试时，则每个测试的输出都被重定向到 logs 目录中一个以 unittests.cfg 文件中测试名称命名的文件中，例如 arm/arm64 的 pci-test 的输出被记录到 'logs/pci-test.log' 中。

>  **构建和运行独立测试**

```sh
make standalone
tests/hypercall # 运行一个独立测试的示例
```
测试可以通过 `make install` 安装，它会将每个测试的独立版本复制到 `$PREFIX/share/kvm-unit-tests/`

### Running tests via Avocado

`kvm-unit-tests` 可以使用 Avocado kvm-unit-tests 运行脚本作为 Avocado 外部测试套件运行。使用 `sh run-kvm-unit-test.sh -h` 检查可用选项。默认情况下，它会下载最新的 kvm-unit-tests 并运行所有可用的测试。

```sh
$ sh contrib/testsuites/run-kvm-unit-test.sh 
JOB ID     : 216c5cf937b07befd9d2bc1dd496714fce280f22
JOB LOG    : /home/medic/avocado/job-results/job-2017-02-23T16.49-216c5cf/job.log
 (01/42) access: PASS (4.46 s)
 (02/42) apic: FAIL (4.42 s)
 (03/42) apic-split: FAIL (4.41 s)
...
 (41/42) vmx: FAIL (1.64 s)
 (42/42) xsave: PASS (1.28 s)
RESULTS    : PASS 33 | ERROR 0 | FAIL 9 | SKIP 0 | WARN 0 | INTERRUPT 0
TESTS TIME : 114.34 s
JOB HTML   : /home/medic/avocado/job-results/job-2017-02-23T16.49-216c5cf/html/results.html
```

## 1.6 Adding a test

1. **创建新单元测试的主代码文件**

   ```c
   $ cat > x86/new-unit-test.c
   #include <libcflat.h>
   
   int main(int ac, char **av)
   {
       report(true, "hello!");
       return report_summary();
   }
   ```

2. **确保适当的 makefile，例如 x86/Makefile.common，已经通过添加它到一个 tests 变量中而被更新**

   ```sh
   tests-common += $(TEST_DIR)/new-unit-test.flat
   ```

   注意，`tests-common` 变量标识了在类似架构之间共享的测试，例如 i386 和 x86_64 或 arm 和 arm64。使用特定架构 makefile 的 tests makefile 变量，特别为该架构构建测试。

3. **现在你可以构建并运行测试了**

   ```sh
   ./configure
   make
   x86/run x86/new-unit-test.flat
   ```

## 1.7 Contributing

要贡献新测试或对框架的增强和修复，请向 KVM 邮件列表提交补丁，并在主题中添加额外标签 `kvm-unit-tests`，即 `[kvm-unit-tests PATCH]`。