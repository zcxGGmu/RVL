# -1 TODO-List

- [ ] `local_irq/preempt_enable/disable`
- [ ] `kvm_riscv_vcpu_unpriv_read`
- [ ] `vcpu_sbi_ext_*`

- [x] 🎈vcpu调度
- [x] 🎈`gstage_page_fault`

# 0 说明

研究KVM代码是无法脱离用户态程序的，否则整个逻辑无法串起来，QEMU奇妙且复杂的机制容易让人深陷其中，为了更好的聚焦到KVM实现，还是选择kvmtool作为对接KVM的用户态程序比较好，而且看起来kvmtool也是社区认可且积极推动的一个虚拟化组件，提交PATCH前完全可以用kvmtool来验证功能。

代码分析，就顺着kvmtool的虚拟机构建、vCPU创建等流程，介入kvm的时候再进一步分析。

> 本文分析的代码version：
>
> | software       | commit id                                |
> | -------------- | ---------------------------------------- |
> | linux-v6.9-rc6 | e67572cd2204894179d89bd7b984072f19313b03 |
> | kvmtool        | da4cfc3e540341b84c4bbad705b5a15865bc1f80 |

# 1 CPU虚拟化介绍

## 1.1 敏感非特权指令的处理

在现代计算机架构中，CPU通常拥有两个或两个以上的特权级，其中操作系统运行在最高特权级，其余程序则运行在较低的特权级。而一些指令必须运行在最高特权级中，若在非最高特权级中执行这些指令，将会触发特权级切换，陷入最高特权级中，这类指令称为**特权指令。**在虚拟化环境中，还有另一类指令称为**敏感指令，**即操作敏感物理资源的指令，如I/O指令、页表基地址切换指令等。

**虚拟化系统的三个基本要求：资源控制、等价与高效。**资源控制要求，Hypervisor能够控制所有的物理资源，虚拟机对敏感物理资源（部分寄存器、I/O设备等）的访问，都应在Hypervisor的监控下进行。这意味着在虚拟化环境中，Hypervisor应当替代虚拟机操作系统运行在最高特权级，管理物理资源并向上提供服务，当虚拟机执行敏感指令时，必须陷入Hypervisor（通常称为虚拟机下陷）中进行模拟，这种敏感指令的处理方式称为 **“陷入-模拟”** 方式。

“陷入-模拟” 方式要求，所有的敏感指令都能触发特权级切换，从而能够陷入Hypervisor中处理，通常将所有敏感指令都是特权指令的架构称为**可虚拟化架构，**反之存在敏感非特权指令的架构称为**不可虚拟化架构。**遗憾的是，大多数计算机架构，在设计之初并未将虚拟化技术考虑在内。

> 以早期的x86架构为例，其SGDT（Store Global Descriptor Table，存储全局描述符表）指令将GDTR（Global Descriptor Table Register，全局描述符表寄存器）的值存储到某个内存区域中，其中全局描述符表用于寻址，属于敏感物理资源，但是在x86架构中，SGDT指令并非特权指令，无法触发特权级切换。

在x86架构中类似SGDT的敏感非特权指令多达17条，Intel将这些指令称为“虚拟化漏洞”。在不可虚拟化架构下，为了使Hypervisor截获并模拟上述敏感非特权指令，一系列软件方案应运而生，下面介绍这些软件解决方案。

### 1) 纯软件方式

敏感非特权指令的软件解决方案，主要包括：解释执行、二进制翻译、扫描与修补以及半虚拟化技术。

* **解释执行技术。**解释执行技术，采用软件模拟的方式逐条模拟虚拟机指令的执行。解释器将程序二进制解码后，调用指令相应的模拟函数，对寄存器的更改，则变为修改保存在内存中的虚拟寄存器的值。
* **二进制翻译技术。**区别于解释执行技术不加区分地翻译所有指令，二进制翻译技术则以基本块为单位，将虚拟机指令批量翻译后，保存在代码缓存中，基本块中的敏感指令会被替换为一系列其他指令。
* **扫描与修补技术。**扫描与修补技术，是在执行每段代码前对其进行扫描，找到其中的敏感指令，将其替换为特权指令，当CPU执行翻译后的代码时，遇到替换后的特权指令，便会陷入Hypervisor中进行模拟，执行对应的补丁代码。
* **半虚拟化技术。**上述三种方式，都是通过扫描二进制代码找到其中敏感指令，半虚拟化则允许虚拟机在执行敏感指令时，通过超调用主动陷入Hypervisor中，避免了扫描程序二进制代码引入的开销。

上述解决方案的优缺点，如下表所示：

<img src="https://cdn.jsdelivr.net/gh/MaskerDad/BlogImage@main/202311221415290.png" alt="image-20231122141503318" style="zoom:33%;" />

这几种方案，通过软件模拟解决了敏感非特权指令问题，但却产生了巨大的软件开销。**敏感非特权指令究其本质是: 硬件架构缺乏对于敏感指令下陷的支持，**近年来各主流架构都从架构层面弥补了 “虚拟化漏洞” ，解决了敏感非特权指令的 “陷入-模拟” 问题，下面简要介绍这些硬件解决方案。

### 2) 硬件虚拟化支持

前面提到，敏感非特权指令存在的根本原因是: 硬件架构缺乏对敏感指令下陷的支持。因此最简单的一种办法是更改现有的硬件架构，将所有的敏感指令都变为特权指令，使之能触发特权级切换，但是这将改变现有指令的语义，现有系统也必须更改来适配上述改动。

另一种办法是**引入虚拟化模式。**未开启虚拟化模式时，操作系统与应用程序运行在原有的特权级，一切行为如常，兼容原有系统；开启虚拟化模式后，Hypervisor运行在最高特权级，虚拟机操作系统与应用程序运行在较低特权级，虚拟机执行敏感指令时，将会触发特权级切换陷入Hypervisor中进行模拟。

虚拟化模式与非虚拟化模式架构，如图2-1所示：

<img src="https://cdn.jsdelivr.net/gh/MaskerDad/BlogImage@main/202311221417410.png" alt="image-20231122141655482" style="zoom: 50%;" />

> 注：①陷入；②恢复；③开启虚拟化模式；④关闭虚拟化模式。

非虚拟化模式通常只需要两个特权级，而虚拟化模式需要至少三个特权级用于区分虚拟机应用程序、虚拟机操作系统与Hypervisor的控制权限，此外还需要引入相应的指令，开启和关闭虚拟化模式。虚拟化模式对现有软件影响较小，Hypervisor能够作为独立的抽象层运行于系统中，因此当下大多数虚拟化硬件都采用该方式：

* **Intel VT-x**为CPU引入了根模式与非根模式，分别供Hypervisor和虚拟机运行；
* **ARM v8**在原有EL0与EL1的基础上，引入了新的异常级EL2供Hypervisor运行；
* **RISC-V Hypervisor Extension**则添加了两个额外的特权级，即VS/VU供虚拟机操作系统和虚拟机应用程序运行，原本的S特权级变为HS，Hypervisor运行在该特权级下。

虚拟化模式的引入，解决了敏感非特权指令的陷入以及系统兼容性问题，但是**特权级的增加也带来了上下文切换问题。**下面介绍虚拟化环境中的上下文切换。

## 1.2 虚拟化场景下的上下文切换

### 1) vCPU world-switch

[RISC-V: KVM: Implement VCPU world-switch · zcxGGmu/linux@34bde9d (github.com)](https://github.com/zcxGGmu/linux/commit/34bde9d8b9e6e5249db3c07cf1ebfe75c23c671c)

`world-switch`，这个commit有着很贴切的描述，就像裸机上从U mode陷入S mode一样，这也是不同的world，由特权级所区分的world，到了虚拟化这里似乎变成了平行世界 :) 。

在操作系统的进程上下文切换中，操作系统与用户态程序运行在不同的特权级中，当用户态程序发起系统调用时，需要将部分程序状态保存在内存中，待系统调用完成后再从内存中恢复程序状态。

而在虚拟化环境下，当虚拟机执行敏感指令时，需要陷入Hypervisor进行处理，Hypervisor与虚拟机同样运行在不同的特权级中，因此硬件应当提供一种机制，在发生虚拟机下陷时保存虚拟机的上下文。等到敏感指令模拟完成后，当虚拟机恢复运行时重新加载虚拟机上下文。

> 此处，“虚拟机上下文” 表述可能有些不准确，更准确的说法应当是 “vCPU上下文”。

一个虚拟机中可能包含多个vCPU，虚拟机中指令执行单元是vCPU，Hypervisor调度虚拟机运行的基本单位也是vCPU。当vCPU A执行敏感指令陷入Hypervisor时，vCPU B将会继续运行。在大部分Hypervisor中，vCPU对应一个线程，通过分时复用的方式共享物理CPU。

以vCPU切换为例，说明上下文切换的流程，vCPU切换流程如下图所示，其中**实线表示控制流，虚线表示数据流。**

<img src="https://cdn.jsdelivr.net/gh/MaskerDad/BlogImage@main/202311221419129.png" alt="image-20231122141910313" style="zoom:50%;" />

> 注：①保存vCPU寄存器；②加载Hypervisor寄存器；③保存Hypervisor寄存器；④加载vCPU寄存器；⑤指令执行顺序。

可以看到：

1. 当vCPU 1时间片用尽时，Hypervisor将会中断vCPU 1执行，vCPU 1陷入Hypervisor中（见图中标号I）。
2. 在此过程中，硬件将vCPU 1的寄存器状态保存至固定区域（见图中标号①），并从中加载Hypervisor的寄存器状态（见图中标号②）。
3. Hypervisor进行vCPU调度，选择下一个运行的vCPU，保存Hypervisor的寄存器状态（见图中标号③），并加载选定的vCPU 2的寄存器状态（见图中标号④），而后恢复vCPU 2运行（见图中标号II）。

上述固定区域与系统架构实现密切相关，以Intel VT-x/ARMv8/RISCV-H为例：

* 在Intel VT-x中，虚拟机与Hypervisor寄存器状态保存在VMCS（Virtual Machine Control Structure，虚拟机控制结构）中，VMCS是内存中的一块固定区域，通过 `VMREAD/VMWRITE` 指令进行读写。
* 在ARM v8中，为EL1和EL2提供了两套系统寄存器，因此单纯发生虚拟机下陷时，无须保存寄存器状态；但是虚拟机下陷后，若要运行其他vCPU，则需要将上一个vCPU状态保存至内存中。
* 在RISC-V H Extension中，为HS mode和VS mode提供了两套寄存器，分别为 `s_*/vs_*`，当虚拟机操作系统在VS mode下访问 `s_*` 寄存器时，硬件将其重定向至 `vs_*` 寄存器。因此，发生vCPU world switch时，并不需要保存vCPU对应的VS模式下的CSR，需要保存的vCPU状态包括：通用寄存器`x0~x31` 以及一些HS mode CSR，然后恢复Hypervisor相应的这些状态。

### 2) host context-switch

在vCPU的视角下，除了Hypervisor代替其执行异常以外，物理CPU就像是被其独占一样。但站在Host的角度看，vCPU只是其创建的一个普通线程，因此它也需要被Host OS的调度器管理。当为vCPU线程分配的时间片用完以后，其需要让出物理CPU。在其再一次被调度时，其又需要切入Guest运行。因此，在vCPU相关的线程切换时，会同时涉及以下两部分上下文：

* vCPU所在的普通线程上下文；
* vCPU Guest和Host之间切换的上下文，即 `world-switch`；

那么如何在切换vcpu线程时，触发guest和host的切入切出操作呢？让我们想一下内核的一贯做法，如内核在执行某操作时需要其它模块配合，它就可以提供一个 `notifier`。需要配合的模块将自己的回调函数注册到该 `notifier` 中，当该操作实际执行时，可以遍历并执行 `notifier` 中已注册的函数。从而使对该操作感兴趣的模块，在其回调函数中定制自身的逻辑。

为了使被调度线程在调度时，能执行其特定的函数，调度器也为每个线程提供了一个通知链 `preempt_notifiers` ，因此vcpu可以向 `preempt_notifiers` 注册一个通知，在线程被sched out或sched in时，调度器将调用其所注册的通知处理函数。而vcpu只需要在通知处理函数中，实现vcpu的切入切出操作即可。以下为其流程图：

![img](https://pic1.zhimg.com/v2-ebebe7c47fbb7a7f15f359b6b1d74a4c_720w.jpg?source=d16d100b)

该流程原理如下：

1. vcpu运行前，向 `preempt_notifiers` 通知链注册一个通知，该通知包含其对应线程被seched in和sched out时需要执行的回调函数；
2. 当vcpu正在运行guest程序时。host触发timer中断，并在中断处理流程中检测到vcpu线程的时间片已用完，因此触发线程调度流程；
3. 调度器调用 `preempt_notifiers`，通知链中所有已注册通知的sched out回调函数；
4. 该回调函数执行vcpu切出操作，在该操作中先保存guest上下文，然后恢复vcpu对应线程的host上下文；
5. vcpu切出完成后，就可以执行host的线程切换流程了。此时需要保存host线程的上下文，然后恢复下一个需要运行线程的上下文；
6. 当该线程再次被调度后，则会执行上图右边的操作。其流程为线程切出时的逆操作；

> 从kvm-riscv架构上看，host vCPU调度涉及三次上下文切换，包括：
>
> * vCPU Guest/Host GPRs：vCPU world-switch
> * vCPU Guest/Host CSRs：vcpu_load/vcpu_put
> * Host vCPU1/vcPU2：task_struct->ctx context_switch

## 1.3 QEMU+KVMTOOL/KVM虚拟化框架

QEMU原本是纯软件实现的一套完整的虚拟化方案，支持CPU虚拟化、内存虚拟化以及设备模拟等，但是性能不太理想。随着硬件辅助虚拟化技术逐渐兴起，Qumranet公司基于新兴的虚拟化硬件实现了KVM。KVM遵循Linux的设计原则，以内核模块的形式动态加载到Linux内核中，利用虚拟化硬件加速CPU虚拟化和内存虚拟化流程，I/O虚拟化则交给用户态的QEMU完成，QEMU/KVM架构如下图所示：

<img src="https://cdn.jsdelivr.net/gh/MaskerDad/BlogImage@main/202311221902898.png" alt="image-20231122164858226" style="zoom: 33%;" />

CPU虚拟化主要关心上图的左侧部分，即vCPU是如何创建并运行的，以及当vCPU执行敏感指令触发VM-Exit时，QEMU/KVM又是如何处理这些VM-Exit的。整体流程如下：

1. 当QEMU启动时，首先会解析用户传入的命令行参数，确定创建的虚拟机类型（通过QEMU-machine参数指定）与CPU类型（通过QEMU-cpu参数指定），并**创建相应的机器模型和CPU模型；**
2. 而后QEMU打开KVM模块设备文件并发起 `ioctl(KVM_CREATE_VM)`，**请求KVM创建一个虚拟机。**KVM创建虚拟机相应的结构体并为QEMU返回一个虚拟机文件描述符；
3. QEMU通过虚拟机文件描述符发起 `ioctl(KVM_CREATE_VCPU)` ，**请求KVM创建vCPU。**与创建虚拟机流程类似，KVM创建vCPU相应的结构体并初始化，返回一个vCPU文件描述符；
4. QEMU通过vCPU文件描述符发起 `ioctl(KVM_RUN)`，vCPU线程执行 `VMLAUNCH` 指令**进入非根模式，**执行虚拟机代码直至发生VM-Exit；
5. KVM根据VM-Exit的原因进行相应处理，如果与I/O有关，则需要进一步**返回到QEMU中**进行处理。

以上就是QEMU/KVM CPU虚拟化的主要流程。

# 2 KVM初始化

kvm初始化的主要目的，是为虚拟机的创建和运行提供必要的软硬件环境，这个过程在宿主机内核启动时进行，其总体流程如下：

![img](https://img2020.cnblogs.com/blog/1771657/202009/1771657-20200912222700148-1239477465.png)

```rust
// riscv/kvm/main.c

static int __init riscv_kvm_init(void)
	+-> riscv_isa_extension_available
	+-> sbi_spec_is_0_1
	+-> sbi_probe_extension(SBI_EXT_RFENCE)
	+-> kvm_riscv_gstage_mode_detect()
	+-> kvm_riscv_gstage_vmid_detect()
	+-> kvm_riscv_aia_init
	+-> kvm_init
		+-> cpuhp_setup_state_nocalls
		+-> register_syscore_ops(&kvm_syscore_ops)
		+-> kmem_cache_create_usercopy
		+-> kvm_irqfd_init
		+-> kvm_async_pf_init
		+-> kvm_init_debug
		+-> kvm_preempt_ops.sched_in = kvm_sched_in
		+-> kvm_preempt_ops.sched_out = kvm_sched_out
		+-> misc_register(&kvm_dev)
		+-> kvm_vfio_ops_init
```

除riscv架构相关的初始化外，还调用了 `kvm_init` 公共初始化函数，其主要包含以下几部分：

* 为电源管理接口注册回调函数，以处理kvm在电源管理流程中的行为
* 为kvm注册字符设备以为用户态提供ioctl接口
* 其它一些辅助接口

### 电源管理回调注册

由于在cpu热插拔和系统休眠唤醒流程中，需要执行cpu的 `offline/online` 状态转换，因此对于需要控制cpu的相关模块，在这一流程中需要正确管理本模块的cpu状态设置。在电源管理流程中，相关模块可以向电源管理模块注册回调，当对应的电源管理事件发生时，该回调函数将会被调用。其中：

* `cpuhp_setup_state_nocalls `用于注册cpu热插拔时的回调；
* `register_syscore_ops` 用于注册系统休眠唤醒时的回调；
* `register_reboot_notifier` 用于注册系统重启时的通知；

它们最终都由 `kvm_arch_hardware_enable` 和 `kvm_arch_hardware_disable` 实现，用于在cpu下线时关闭hypervisor，并在cpu上线时重新初始化hypervisor。

```c
/* Exception causes */
//#define EXC_INST_MISALIGNED	0
#define EXC_INST_ACCESS		1
#define EXC_INST_ILLEGAL	2
//#define EXC_BREAKPOINT		3
#define EXC_LOAD_MISALIGNED	4
#define EXC_LOAD_ACCESS		5
#define EXC_STORE_MISALIGNED	6
#define EXC_STORE_ACCESS	7
//#define EXC_SYSCALL		8
#define EXC_HYPERVISOR_SYSCALL	9
#define EXC_SUPERVISOR_SYSCALL	10
//#define EXC_INST_PAGE_FAULT	12
//#define EXC_LOAD_PAGE_FAULT	13
//#define EXC_STORE_PAGE_FAULT	15
#define EXC_INST_GUEST_PAGE_FAULT	20
#define EXC_LOAD_GUEST_PAGE_FAULT	21
#define EXC_VIRTUAL_INST_FAULT		22
#define EXC_STORE_GUEST_PAGE_FAULT	23

/* Interrupt causes (minus the high bit) */
#define IRQ_S_SOFT		1
//#define IRQ_VS_SOFT		2
#define IRQ_M_SOFT		3
#define IRQ_S_TIMER		5
//#define IRQ_VS_TIMER		6
#define IRQ_M_TIMER		7
#define IRQ_S_EXT		9
//#define IRQ_VS_EXT		10
#define IRQ_M_EXT		11
#define IRQ_S_GEXT		12
#define IRQ_PMU_OVF		13

int kvm_arch_hardware_enable(void)
{
	unsigned long hideleg, hedeleg;

	hedeleg = 0;
	hedeleg |= (1UL << EXC_INST_MISALIGNED);
	hedeleg |= (1UL << EXC_BREAKPOINT);
	hedeleg |= (1UL << EXC_SYSCALL);
	hedeleg |= (1UL << EXC_INST_PAGE_FAULT);
	hedeleg |= (1UL << EXC_LOAD_PAGE_FAULT);
	hedeleg |= (1UL << EXC_STORE_PAGE_FAULT);
	csr_write(CSR_HEDELEG, hedeleg);

	hideleg = 0;
	hideleg |= (1UL << IRQ_VS_SOFT);
	hideleg |= (1UL << IRQ_VS_TIMER);
	hideleg |= (1UL << IRQ_VS_EXT);
	csr_write(CSR_HIDELEG, hideleg);

	/* VS should access only the time counter directly. Everything else should trap */
	csr_write(CSR_HCOUNTEREN, 0x02);

	csr_write(CSR_HVIP, 0);

	kvm_riscv_aia_enable();

	return 0;
}

void kvm_arch_hardware_disable(void)
{
	kvm_riscv_aia_disable();

	/*
	 * After clearing the hideleg CSR, the host kernel will receive
	 * spurious interrupts if hvip CSR has pending interrupts and the
	 * corresponding enable bits in vsie CSR are asserted. To avoid it,
	 * hvip CSR and vsie CSR must be cleared before clearing hideleg CSR.
	 */
	csr_write(CSR_VSIE, 0);
	csr_write(CSR_HVIP, 0);
	csr_write(CSR_HEDELEG, 0);
	csr_write(CSR_HIDELEG, 0);
}
```

> 关于 EXC_INST_MISALIGNED 代理到 VS mode：
>
> Instruction address misaligned exceptions are raised by control-flow instructions with misaligned
> targets, rather than by the act of fetching an instruction. Therefore, these exceptions have lower
> priority than other instruction address exceptions.

* 对于 `kvm_arch_hardware_enable`，将一些应该由VS mode接管的异常、中断，通过 `hideleg/hedeleg` 进行代理，该函数的调用路径如下：

  ```c
  /* 创建虚拟机时，初始化hypervisor设置 */
  kvm_dev_ioctl(KVM_CREATE_VM)
  	+-> kvm_dev_ioctl_create_vm
  		+-> kvm_create_vm
  			+-> hardware_enable_all
                  +-> hardware_enable_nolock
                      +-> __hardware_enable_nolock
                          +-> kvm_arch_hardware_enable
  
  /* 当相应电源事件发生时，调用kvm_online_cpu/kvm_resume初始化hypervisor设置 */
  kvm_init
      +-> {
          #ifdef CONFIG_KVM_GENERIC_HARDWARE_ENABLING
              r = cpuhp_setup_state_nocalls(CPUHP_AP_KVM_ONLINE, "kvm/cpu:online",
                                            kvm_online_cpu, kvm_offline_cpu);
              if (r)
                  return r;
  
              register_syscore_ops(&kvm_syscore_ops);
          #endif
  		}
  		+-> kvm_online_cpu
      		+-> __hardware_enable_nolock
              	+-> kvm_arch_hardware_enable
      
  kvm_resume
      +-> __hardware_enable_nolock
          +-> kvm_arch_hardware_enable
  kvm_init
      +-> register_syscore_ops(&kvm_syscore_ops);
  
  static struct syscore_ops kvm_syscore_ops = {
  	.suspend = kvm_suspend,
  	.resume = kvm_resume,
  	.shutdown = kvm_shutdown,
  };
  ```

 * 对于 `kvm_arch_hardware_disable`，在清除 hideleg 之后，如果 hvip 具有挂起中断，且 vsie 中对应的使能位已经被设置，则Host内核将会收到虚拟机中断。为了避免这种情况发生，在清除 hideleg 之前必须先清除 hvip CSR 和 vsie CSR。

### ioctl接口注册

kvm一共为用户态提供了三组ioctl接口：`kvm ioctl`、`vm ioctl` 和 `vcpu ioctl`。它们分别为用于控制kvm全局、特定虚拟机以及特定vcpu相关的操作。其中：

* kvm全局ioctl通过 `misc_register` 接口以字符设备的方式注册；
* 而 `vm ioctl` 和 `vcpu ioctl` 则通过 `anon_inode_getfd` 接口以匿名inode方式注册；

Linux中一般的文件都包含一个inode和与若干个其关联的dentry，其中dentry用于表示其在文件系统中的路径。若用户态希望操作该文件时，可通过打开dentry对应的文件名，并获取一个fd。但是有些文件操作希望将 fd 与 inode 直接关联起来，其文件名不在文件系统中被显示，这就是匿名inode。

> vm的匿名inode，在虚拟机创建流程中建立：

![img](https://pic3.zhimg.com/v2-ac36ac7302c1a2a569856b2dab6f4dd2_b.jpg)

> vcpu的匿名inode，同样在vcpu创建流程中建立，其流程如下：

![img](https://pic1.zhimg.com/v2-2333eb044bc6426c264e9587e304e710_b.jpg)

### 其它辅助接口

* `kvm_irqfd_init`：为eventfd创建一个全局的工作队列，它用于在虚拟机被关闭时，关闭所有与其相关的irqfd，并等待该操作完成；

* `kmem_cache_create_usercopy` 和 `kvm_async_pf_init` 用于创建特定的slab；
* `kvm_init_debug` 用于为kvm创建debugfs相关接口；
* `kvm_vfio_ops_init` 用于为vfio注册设备回调函数；

# 3 虚拟机创建

## 3.1 kvmtool基本框架

首先需要说明的是，GNU `__attribute__` 机制可以设置函数属性（Function Attribute), 变量属性(Variable Attribute), 类型属性(Type Attribute)。它的基本语法如下所示：`__attribute__` (parameter)。

```c
#define __exit_list_add(cb, l)						\
static void __attribute__ ((constructor)) __init__##cb(void)		\
{									\
	static char name[] = #cb;					\
	static struct init_item t;					\
	exit_list_add(&t, cb, l, name);					\
}
```

**属性constructor/destructor：**若函数被设定为constructor属性，则该函数会在 main 函数执行之前被自动执行。类似的，若函数被设定为destructor属性，则该函数会在 main 函数执行之后，或者 exit 被调用后被自动执行。**拥有此类属性的函数，经常隐式的用在程序的初始化数据方面。**

---

KVMTOOL定义了一系列init宏，用来将一系列初始化函数在main函数执行前，添加到函数链表 `init_lists` 中。

```c
static struct hlist_head init_lists[PRIORITY_LISTS];

int init_list_add(struct init_item *t, int (*init)(struct kvm *),
			int priority, const char *name)
{
	t->init = init;
	t->fn_name = name;
	hlist_add_head(&t->n, &init_lists[priority]);

	return 0;
}

int init_list_add(struct init_item *t, int (*init)(struct kvm *),
			int priority, const char *name);

#define __init_list_add(cb, l)						\
static void __attribute__ ((constructor)) __init__##cb(void)		\
{									\
	static char name[] = #cb;					\
	static struct init_item t;					\
	init_list_add(&t, cb, l, name);					\
}

#define core_init(cb) __init_list_add(cb, 0)
#define base_init(cb) __init_list_add(cb, 2)
#define dev_base_init(cb)  __init_list_add(cb, 4)
#define dev_init(cb) __init_list_add(cb, 5)
#define virtio_dev_init(cb) __init_list_add(cb, 6)
#define firmware_init(cb) __init_list_add(cb, 7)
#define late_init(cb) __init_list_add(cb, 9)
#endif
```

这些 `init` 函数主要包括：

![img](https://pic1.zhimg.com/v2-94d8555ad1a122c5892529a7de5cc120_b.jpg)

在main函数中，KVMTOOL在完成命令行解析与配置后，会遍历 `init_lists` 链表，执行初始化函数进行初始化工作，调用链如下：

```c
main
    +-> handle_kvm_command
    	+-> handle_command
    		+-> kvm_cmd_run
    			+-> kvm_cmd_run_init
    				+-> init_list__init
    
int init_list__init(struct kvm *kvm)
{
	unsigned int i;
	int r = 0;
	struct init_item *t;

	for (i = 0; i < ARRAY_SIZE(init_lists); i++)
		hlist_for_each_entry(t, &init_lists[i], n) {
			r = t->init(kvm);
			if (r < 0) {
				pr_warning("Failed init: %s\n", t->fn_name);
				goto fail;
			}
		}
    
fail:
	return r;
}
```

## 3.2 kvm__init创建虚拟机主流程

`kvm__init` 整体流程，如下：

```c
+-> kvm__init
    +-> kvm->sys_fd = open(kvm->cfg.dev, O_RDWR);
    +-> ret = ioctl(kvm->sys_fd, KVM_GET_API_VERSION, 0);
    +-> kvm->vm_fd = ioctl(kvm->sys_fd, KVM_CREATE_VM, kvm__get_vm_type(kvm));
    +-> kvm__check_extensions(kvm);
		for{} => 
		+-> kvm__supports_extension(kvm, kvm_req_ext[i].code))
            +-> ioctl(kvm->sys_fd, KVM_CHECK_EXTENSION, extension);
				+-> kvm_vm_ioctl_check_extension(kvm, arg);
    +-> kvm__arch_init(kvm);
		+-> kvm->arch.ram_alloc_start = mmap_anon_or_hugetlbfs(kvm,
						kvm->cfg.hugetlbfs_path,
						kvm->arch.ram_alloc_size);
		+-> riscv__irqchip_create(kvm);
    /*
       riscv/kvm.c:
       mmap一块内存为VM使用，同时riscv__irqchip_create进行中断相关的初始化
       包括aia__create/plic__create,
    */
    +-> kvm__init_ram(kvm);
    	+-> // 虚拟机地址空间的基本属性
        	phys_start	= RISCV_RAM;      // guest系统内存的起始地址(gpa)
    		phys_size	= kvm->ram_size;  // 内存大小
    		host_mem	= kvm->ram_start; // hva的起始地址
    	+-> kvm__register_ram(kvm, phys_start, phys_size, host_mem);
   			// kvmtool向kvm注册memory的过程，单独分析
    +-> if(!kvm->cfg.firmware_filename) //没设置固件的情况
        +-> kvm__load_kernel //加载kernel/DTB到指定位置处
    +-> if (kvm->cfg.firmware_filename) //设置固件的情况
        +-> kvm__load_firmware
        +-> kvm__arch_setup_firmware
```

* 打开 `/dev/kvm`，获取全局kvm_fd；

* `ioctl(kvm->sys_fd, KVM_GET_API_VERSION, 0)`，kvm会返回一个KVM_API_VERSION；

* `ioctl(kvm->sys_fd, KVM_CREATE_VM, kvm__get_vm_type(kvm))` 创建一个匿名vm_fd，后续用户态可以操作vm_fd，进行虚拟机粒度的操作；

* `kvm_vm_ioctl_check_extension` 用于检查，用户态配置的 `KVM_CAP_*` 是否支持；

* `kvm__arch_init` 做了两件事：

  1）mmap一块空间作为虚拟机RAM，此时确定了 `hva_start/hva_size`；

  2）`riscv__irqchip_create` 依次尝试创建虚拟中断控制器，aia在kvm中模拟，plic在kvmtool中模拟；

  ```c
  static void (*riscv__irqchip_create_funcs[])(struct kvm *kvm) = {
  	aia__create,
  	plic__create,
  };
  
  void riscv__irqchip_create(struct kvm *kvm)
  {
  	unsigned int i;
  
  	/* Try irqchip.create function one after another */
  	for (i = 0; i < ARRAY_SIZE(riscv__irqchip_create_funcs); i++) {
  		riscv__irqchip_create_funcs[i](kvm);
  		if (riscv_irqchip != IRQCHIP_UNKNOWN)
  			return;
  	}
  
  	/* Fail since irqchip is unknown */
  	die("No IRQCHIP found\n");
  }
  ```

* `kvm__init_ram` 单独描述；
* `kernel/firmware_load` 单独描述； 

### 1) 虚拟机内存注册: kvm__init_ram

此处重点分析 `kvm_init_ram`，该函数主要负责在host侧分配虚拟机内存并将其注册给KVM。这相当于在机箱中安装内存。其中 `kvm->ram_size` 是要安装的内存大小，该字段在 `kvm__arch_init` 中被初始化：

```c
void kvm__arch_init(struct kvm *kvm)
{
    /*
     * 分配客户机内存。我们必须将我们的缓冲区对齐到64K，
     * 以便与virtio-mmio的最大客户机页面大小相匹配。
     * 如果使用THP（透明大页），那么我们的最小对齐值变为巨页
     * 大小。巨页大小总是大于64K，所以让我们采用这个值。
     */
    //在Host侧位Guest申请内存，这段空间就是HVA
	kvm->ram_size = min(kvm->cfg.ram_size, (u64)RISCV_MAX_MEMORY(kvm));
	kvm->arch.ram_alloc_size = kvm->ram_size;
	if (!kvm->cfg.hugetlbfs_path)
		kvm->arch.ram_alloc_size += HUGEPAGE_SIZE;
	kvm->arch.ram_alloc_start = mmap_anon_or_hugetlbfs(kvm,
						kvm->cfg.hugetlbfs_path,
						kvm->arch.ram_alloc_size);

	if (kvm->arch.ram_alloc_start == MAP_FAILED)
		die("Failed to map %lld bytes for guest memory (%d)",
		    kvm->arch.ram_alloc_size, errno);
	//与virtio-mmio区间对齐，ram_alloc_start为原始指针，ram_start是对齐后的起始地址
	kvm->ram_start = (void *)ALIGN((unsigned long)kvm->arch.ram_alloc_start,
					SZ_2M);
	
    //建议内核优化内存访问和页面管理
	madvise(kvm->arch.ram_alloc_start, kvm->arch.ram_alloc_size,
		MADV_MERGEABLE);

	madvise(kvm->arch.ram_alloc_start, kvm->arch.ram_alloc_size,
		MADV_HUGEPAGE);

}
```

- 第一行`madvise(kvm->arch.ram_alloc_start, kvm->arch.ram_alloc_size, MADV_MERGEABLE);`的调用建议内核，标记由`kvm->arch.ram_alloc_start`开始、大小为`kvm->arch.ram_alloc_size`的内存区域可以合并（mergeable）。这通常用于启用KSM（Kernel SamePage Merging，内核同页合并），KSM是一种内存节省技术，它通过查找内容相同的内存页并将它们合并为一个来减少内存使用。
- 第二行`madvise(kvm->arch.ram_alloc_start, kvm->arch.ram_alloc_size, MADV_HUGEPAGE);`的调用向内核表明，同一个内存区域应被视为使用大页（huge pages）的候选者。大页（或巨型页）技术通过使用更大的内存页（例如2MB或1GB，而不是默认的4KB）来减少页面表项的数量，从而改善应用程序的性能，特别是在处理大量数据时。

> `madvise`函数的一般形式是：
>
> ```c
> int madvise(void *addr, size_t length, int advice);
> ```
>
> - `addr`是指向内存区域开始的指针。
> - `length`是内存区域的大小。
> - `advice`是一个标志，用于指示应用程序对这段内存的使用模式。
>
> 该函数允许应用程序给内核一个“建议”（advice），告诉内核它对这段内存的期望使用模式。内核可以根据这些信息来优化页面回收算法、页面合并或对这段内存的缓存策略等。使用`madvise`函数可以优化应用程序的性能和内存使用效率，但是它的效果和是否被采纳依赖于操作系统的实现和当前的系统状态。

---

接下来，看 `kvm__init_ram`：

```c
#define RISCV_RAM		0x80000000ULL

void kvm__init_ram(struct kvm *kvm)
{
	int err;
	u64 phys_start, phys_size;
	void *host_mem;

	phys_start	= RISCV_RAM;		//Guest的物理内存起始地址(GPA)
	phys_size	= kvm->ram_size;	//Guest物理内存的大小
	host_mem	= kvm->ram_start;	//Host中为Guest内存分配的空间(HVA)

    //为Guest注册一个内存区域, 物理地址是[RISCV_RAM, RISCV_RAM + kvm->ram_size)
	err = kvm__register_ram(kvm, phys_start, phys_size, host_mem);
	if (err)
		die("Failed to register %lld bytes of memory at physical "
		    "address 0x%llx [err %d]", phys_size, phys_start, err);

	kvm->arch.memory_guest_start = phys_start;
}
```

---

`kvm__register_ram` 负责注册 `KVM_MEM_TYPE_RAM` 类型的内存, 如下：

```c
enum kvm_mem_type {
    KVM_MEM_TYPE_RAM = 1 << 0,  //普通随机访问内存, 也就通常理解的内存
    KVM_MEM_TYPE_DEVICE = 1 << 1,    //设备的板载内存
    KVM_MEM_TYPE_RESERVED = 1 << 2,
    KVM_MEM_TYPE_READONLY = 1 << 3, //只读
    
    KVM_MEM_TYPE_ALL	= KVM_MEM_TYPE_RAM
            | KVM_MEM_TYPE_DEVICE
            | KVM_MEM_TYPE_RESERVED
            | KVM_MEM_TYPE_READONLY
};

static inline int kvm__register_ram(struct kvm* kvm, u64 guest_phys, u64 size, void* userspace_addr)
{
    return kvm__register_mem(kvm, guest_phys, size, userspace_addr, KVM_MEM_TYPE_RAM);
}
```

再往下走，`kvm__register_mem` 负责为Guest注册一片内存区域，可以理解为向主板上某一个插槽插入一条内存(实际为Guest中一片内存区域)。**注册分为两部分：**

- 首先kvmtool自身需要管理Guest的物理内存, 每部分内存用 `struct kvm_mem_bank` 表示，所有的内存区域组织为一个链表，链表头为 `kvm->mem_banks`；
- 之后需要通过KVM为Guest添加一条内存，只有这样Guest才能开始使用这片内存. 这部分可以看KVM的api；

```c
/*
    [guest_phys, guest_phys+size)为Guest的物理地址范围
    userspace_addr为Host中为这部分内存分配的空间
    type表示内存属性
*/
int kvm__register_mem(struct kvm* kvm, u64 guest_phys, u64 size, void* userspace_addr, enum kvm_mem_type type)
{
    struct kvm_userspace_memory_region mem;
    struct kvm_mem_bank* merged = NULL;
    struct kvm_mem_bank* bank;
    struct list_head* prev_entry;
    u32 slot;
    u32 flags = 0;
    int ret;

    mutex_lock(&kvm->mem_banks_lock);   //内存条链表上锁

    /* 检查是否有重叠的内存区域, 并找到第一个空的内存插槽, 暂时不管 */
    slot = 0;
    prev_entry = &kvm->mem_banks;
    ...;

    //新建一个bank并初始化, bank表示一个内存区域
    bank = malloc(sizeof(*bank));
    INIT_LIST_HEAD(&bank->list);  //初始化链表元素
    bank->guest_phys_addr = guest_phys; //guest中这条内存的起始地址(GPA)
    bank->host_addr = userspace_addr;   //Host为这条内存分配的地址(HVA)
    bank->size = size;  //内存大小
    bank->type = type;  //内存类型
    bank->slot = slot;  //这个内存条对应的插槽

    if (type & KVM_MEM_TYPE_READONLY)   //是否只读
        flags |= KVM_MEM_READONLY;

    //通过KVM添加到Guest的物理内存中
    if (type != KVM_MEM_TYPE_RESERVED) {
        //根据该内存条初始化一个struct kvm_userspace_memory_region
        mem = (struct kvm_userspace_memory_region) {  
            .slot = slot,
            .flags = flags,
            .guest_phys_addr = guest_phys,
            .memory_size = size,
            .userspace_addr = (unsigned long)userspace_addr,
        };

        //告诉KVM为Guest添加一个内存条
        ret = ioctl(kvm->vm_fd, KVM_SET_USER_MEMORY_REGION, &mem);
    }

    list_add(&bank->list, prev_entry);  //把这个内存条添加到链表中
    kvm->mem_slots++;   //内存插槽++
    ret = 0;

out:
    mutex_unlock(&kvm->mem_banks_lock);
    return ret;
}
```

### 2) 加载内核与初始文件系统: kvm__load_kernel

内存注册好后，kvmtool还需要将内核以及初始文件系统加载至内存中的指定位置，代码如下：

```c
int kvm__init(struct kvm *kvm) {
    //...
    kvm__arch_init(kvm);

	INIT_LIST_HEAD(&kvm->mem_banks);
	kvm__init_ram(kvm);
    
   	if (!kvm->cfg.firmware_filename) {
		if (!kvm__load_kernel(kvm, kvm->cfg.kernel_filename,
				kvm->cfg.initrd_filename, kvm->cfg.real_cmdline))
			die("unable to load kernel %s", kvm->cfg.kernel_filename);
	}

	if (kvm->cfg.firmware_filename) {
		if (!kvm__load_firmware(kvm, kvm->cfg.firmware_filename))
			die("unable to load firmware image %s: %s", kvm->cfg.firmware_filename, strerror(errno));
	} else {
		ret = kvm__arch_setup_firmware(kvm);
		if (ret < 0)
			die("kvm__arch_setup_firmware() failed with error %d\n", ret);
	}
    
    //...
}

// riscv/kvm.c
bool kvm__load_firmware(struct kvm *kvm, const char *firmware_filename)
{
	/* TODO: Firmware loading to be supported later. */
	return false;
}

int kvm__arch_setup_firmware(struct kvm *kvm)
{
	return 0;
}
```

目前kvmtool没有单独实现固件设置/加载的逻辑，可以参考arm的实现。设置固件时，kvm就不再直接加载kernel image了，而是将fw_addr作为guest切入地址，固件会引导guest os的运行。

```c
bool kvm__load_firmware(struct kvm *kvm, const char *firmware_filename)
{
	//...
    
	/* Kernel isn't loaded by kvm, point start address to firmware */
	kvm->arch.kern_guest_start = fw_addr;
	pr_debug("Loaded firmware to 0x%llx (%zd bytes)",
		 kvm->arch.kern_guest_start, fw_sz);

	/* Load dtb just after the firmware image*/
	host_pos += fw_sz;
	if (host_pos + FDT_MAX_SIZE > limit)
		die("not enough space to load fdt");

	kvm->arch.dtb_guest_start = ALIGN(host_to_guest_flat(kvm, host_pos),
					  FDT_ALIGN);
	pr_debug("Placing fdt at 0x%llx - 0x%llx",
		 kvm->arch.dtb_guest_start,
		 kvm->arch.dtb_guest_start + FDT_MAX_SIZE);

	return true;
}
```

---

接下来，看 `kvm__load_kernel`：

```c
bool kvm__load_kernel(struct kvm *kvm, const char *kernel_filename,
		const char *initrd_filename, const char *kernel_cmdline)
{
	bool ret;
	int fd_kernel = -1, fd_initrd = -1;

	fd_kernel = open(kernel_filename, O_RDONLY);  //打开内核文件
	if (fd_kernel < 0)
		die("Unable to open kernel %s", kernel_filename);

	if (initrd_filename) {
		fd_initrd = open(initrd_filename, O_RDONLY);  //打开初始文件系统
		if (fd_initrd < 0)
			die("Unable to open initrd %s", initrd_filename);
	}

    //加载kernel和initrd到内存中, kernel_cmdline是内核启动时传递的命令
	ret = kvm__arch_load_kernel_image(kvm, fd_kernel, fd_initrd,
					  kernel_cmdline);
	
    //关闭文件
	if (initrd_filename)
		close(fd_initrd);
	close(fd_kernel);

	if (!ret)
		die("%s is not a valid kernel image", kernel_filename);
	return ret;
}
```

重点看 `kvm__arch_load_kernel_image`：

```c
#define FDT_ALIGN	SZ_4M
#define INITRD_ALIGN	8
bool kvm__arch_load_kernel_image(struct kvm *kvm, int fd_kernel, int fd_initrd,
				 const char *kernel_cmdline)
{
	void *pos, *kernel_end, *limit;
	unsigned long guest_addr, kernel_offset;
	ssize_t file_size;

	/*
	 * Linux requires the initrd and dtb to be mapped inside lowmem,
	 * so we can't just place them at the top of memory.
	 */
	limit = kvm->ram_start + min(kvm->ram_size, (u64)SZ_256M) - 1;

#if __riscv_xlen == 64
	/* Linux expects to be booted at 2M boundary for RV64 */
	kernel_offset = 0x200000;
#else
	/* Linux expects to be booted at 4M boundary for RV32 */
	kernel_offset = 0x400000;
#endif
	
    //放置kernel镜像
	pos = kvm->ram_start + kernel_offset;
	kvm->arch.kern_guest_start = host_to_guest_flat(kvm, pos); 	  // HVA -> GPA
	file_size = read_file(fd_kernel, pos, limit - pos); 		  // 读内核镜像到指定位置
	if (file_size < 0) {
		if (errno == ENOMEM)
			die("kernel image too big to fit in guest memory.");

		die_perror("kernel read");
	}
	kernel_end = pos + file_size;
	pr_debug("Loaded kernel to 0x%llx (%zd bytes)",
		 kvm->arch.kern_guest_start, file_size);

	/* Place FDT just after kernel at FDT_ALIGN address */
    //放置设备树FDT文件
	pos = kernel_end + FDT_ALIGN;
	guest_addr = ALIGN(host_to_guest_flat(kvm, pos), FDT_ALIGN);
	pos = guest_flat_to_host(kvm, guest_addr);
	if (pos < kernel_end)
		die("fdt overlaps with kernel image.");

	kvm->arch.dtb_guest_start = guest_addr;
	pr_debug("Placing fdt at 0x%llx - 0x%llx",
		 kvm->arch.dtb_guest_start,
		 host_to_guest_flat(kvm, limit));

	/* ... and finally the initrd, if we have one. */
	//放置initrd根文件系统
    if (fd_initrd != -1) {
		struct stat sb;
		unsigned long initrd_start;
		
        //获取initrd文件的大小等信息
		if (fstat(fd_initrd, &sb))
			die_perror("fstat");
		
        //计算放置initrd的位置，确保它位于内存的某个限制limit之前，并且按照INITRD_ALIGN（initrd对齐要求）对齐
		pos = limit - (sb.st_size + INITRD_ALIGN);
		guest_addr = ALIGN(host_to_guest_flat(kvm, pos), INITRD_ALIGN);
		pos = guest_flat_to_host(kvm, guest_addr);
		if (pos < kernel_end)
			die("initrd overlaps with kernel image.");

		initrd_start = guest_addr;
        //读initrd到内存指定位置
		file_size = read_file(fd_initrd, pos, limit - pos);
		if (file_size == -1) {
			if (errno == ENOMEM)
				die("initrd too big to fit in guest memory.");

			die_perror("initrd read");
		}

		kvm->arch.initrd_guest_start = initrd_start;
		kvm->arch.initrd_size = file_size;
		pr_debug("Loaded initrd to 0x%llx (%llu bytes)",
			 kvm->arch.initrd_guest_start,
			 kvm->arch.initrd_size);
	} else {
		kvm->arch.initrd_size = 0;
	}

	return true;
}

static int setup_fdt(struct kvm *kvm)
{
    //...
    
   	/* Initrd */
	if (kvm->arch.initrd_size != 0) {
		u64 ird_st_prop = cpu_to_fdt64(kvm->arch.initrd_guest_start);
		u64 ird_end_prop = cpu_to_fdt64(kvm->arch.initrd_guest_start +
					       kvm->arch.initrd_size);

		_FDT(fdt_property(fdt, "linux,initrd-start",
				   &ird_st_prop, sizeof(ird_st_prop)));
		_FDT(fdt_property(fdt, "linux,initrd-end",
				   &ird_end_prop, sizeof(ird_end_prop)));
	}
    
    //...
}

late_init(setup_fdt);
```

整体流程就是将 `kernel/FDT/initrd` 这些文件依次加载到内存的指定位置上，此过程中每个文件的起始地址都要按规则对齐，再通过 `host_to_guest_flat(kvm, pos)` 函数得到客户机地址GPA，kvmtool需要记录这些信息并将它们传递给KVM。

具体见：[PATCH v11 kvmtool 6/8\] riscv: Generate FDT at runtime for Guest/VM - Anup Patel (kernel.org)](https://lore.kernel.org/all/20211119124515.89439-7-anup.patel@wdc.com/).

---

至此，`kvm__init` 函数也就结束了，主要涉及虚拟机全局的一些设置：比如内存、中断、内核镜像/设备树/根文件系统的加载等。但真正让虚拟机运行起来的，或者说描述虚拟机运行状态的软件抽象此时还未创建、初始化，这就是 `vcpu`。 

# 4 vCPU创建/初始化

在kvmtool主流程中，该阶段的位置：

```c
main
    +-> handle_kvm_command
    	//kvm-cmd.c定义了kvm_commands数组，保存各种kvmtool命令的处理函数，run对应的是kvm_cmd_run
   		+-> handle_command
    		//builtin-run.c
    		+-> kvm_cmd_run
    			//命令行解析与配置
    			+-> kvm_cmd_run_init
    				/*
    				util/init.c:
    				KVMTOOL定义了一系列init宏，用来在main执行前将一系列初始化函数
    				添加到函数链表init_lists中，在include/kvm/util-init.h 中
    			    若函数被设定为constructor属性，则该函数会在main函数执行之前
    			    被自动的执行。
    				类似的，若函数被设定为destructor属性，则该函数会在main函数执行
    				之后或者exit被调用后被自动的执行。拥有此类属性的函数经常隐式的
    				用在程序的初始化数据方面。		
    				遍历init_lists 链表，执行初始化函数进行初始化工作。
    					core_init(kvm__init);
    					base_init(kvm_cpu__init);
    					dev_init(plic__init);
    					dev_base_init(disk_image__init);
    					dev_base_init(pci__init);
    					virtio_dev_init(virtio_blk__init);
    					late_init(aia__init);
    				*/
    				+-> init_list__init 
    					+-> kvm__init
                        +-> kvm_cpu__init
                            +-> // 有一些确定vcpu的数量的工作	
                            +-> kvm_cpu__arch_init
                            	// 创建、初始化vcpu的工作，单独分析
```

`kvm_cpu__init` 做了两件事：

* 确定虚拟机要创建vcpu数量，通过 `max_cpus/recommended_cpus/kvm->cfg.nrcpus` 确定；
* 调用 `kvm_cpu__arch_init` 初始化每个vcpu； 

下面具体分析。

## 4.1 kvmtool: kvm_cpu_init

`kvm_cpu__init()` 计算出Guest需要多少个CPU，申请cpu指针数组后再调用 `kvm_cpu__arch_init()` 构造一个CPU对象：

```c
static int task_eventfd;  

int kvm_cpu__init(struct kvm* kvm)
{
    int max_cpus, recommended_cpus, i;
	
    //最大CPU数量: ioctl(kvm->sys_fd, KVM_CHECK_EXTENSION, KVM_CAP_MAX_VCPUS);
    max_cpus = kvm__max_cpus(kvm);
    if (kvm->cfg.nrcpus > max_cpus) {
        kvm->cfg.nrcpus = max_cpus;
    }

    kvm->nrcpus = kvm->cfg.nrcpus;    //使用多少个CPU

    task_eventfd = eventfd(0, 0);     //创建一个事件描述符

    /* 分配CPU指针数组, 多申请一个用作末尾的NULL指针 */
    kvm->cpus = calloc(kvm->nrcpus + 1, sizeof(void*));

    //初始化每一个CPU
    for (i = 0; i < kvm->nrcpus; i++) {
        kvm->cpus[i] = kvm_cpu__arch_init(kvm, i);
    }

    return 0;
    ...;    //错误处理
}
base_init(kvm_cpu__init);
```

vcpu对应Host中的一个普通线程，kvmtools使用 `struct kvm_cpu` 表示一个vcpu, 主要字段如下：

```c
struct kvm_cpu {
	pthread_t	thread;

	unsigned long   cpu_id;

	unsigned long	riscv_xlen;
	unsigned long	riscv_isa;
	unsigned long	riscv_timebase;

	struct kvm	*kvm;
	int		vcpu_fd;
	struct kvm_run	*kvm_run;
	struct kvm_cpu_task	*task;

	u8		is_running;
	u8		paused;
	u8		needs_nmi;

	struct kvm_coalesced_mmio_ring	*ring;
};
```

---

调用 `kvm_cpu__arch_init` 创建、初始化vcpu，大致流程直接注释在代码里：

```c
struct kvm_cpu *kvm_cpu__arch_init(struct kvm *kvm, unsigned long cpu_id)
{
	struct kvm_cpu *vcpu;
	u64 timebase = 0;
	unsigned long isa = 0, id = 0;
	unsigned long masks[KVM_REG_RISCV_SBI_MULTI_REG_LAST + 1] = { 0 };
	int i, coalesced_offset, mmap_size;
	struct kvm_one_reg reg;

	vcpu = calloc(1, sizeof(struct kvm_cpu));
	if (!vcpu)
		return NULL;

    //创建匿名文件kvm-vcpu，此后kvmtool可以用vcpu_fd进行vcpu粒度的操作
	vcpu->vcpu_fd = ioctl(kvm->vm_fd, KVM_CREATE_VCPU, cpu_id);
	if (vcpu->vcpu_fd < 0)
		die_perror("KVM_CREATE_VCPU ioctl");

    //获取vcpu-isa
	reg.id = RISCV_CONFIG_REG(isa);
	reg.addr = (unsigned long)&isa;
	if (ioctl(vcpu->vcpu_fd, KVM_GET_ONE_REG, &reg) < 0)
		die("KVM_GET_ONE_REG failed (config.isa)");
	
    //获取vtime
	reg.id = RISCV_TIMER_REG(frequency);
	reg.addr = (unsigned long)&timebase;
	if (ioctl(vcpu->vcpu_fd, KVM_GET_ONE_REG, &reg) < 0)
		die("KVM_GET_ONE_REG failed (timer.frequency)");

    
	mmap_size = ioctl(kvm->sys_fd, KVM_GET_VCPU_MMAP_SIZE, 0);
	if (mmap_size < 0)
		die_perror("KVM_GET_VCPU_MMAP_SIZE ioctl");

    //映射vcpu->kvm_run共享内存，用于在host用户态处理guest异常
	vcpu->kvm_run = mmap(NULL, mmap_size, PROT_RW, MAP_SHARED,
			     vcpu->vcpu_fd, 0);
	if (vcpu->kvm_run == MAP_FAILED)
		die("unable to mmap vcpu fd");

    //MMIO聚合，减少MMIO退出次数
	coalesced_offset = ioctl(kvm->sys_fd, KVM_CHECK_EXTENSION,
				 KVM_CAP_COALESCED_MMIO);
	if (coalesced_offset)
		vcpu->ring = (void *)vcpu->kvm_run +
			     (coalesced_offset * PAGE_SIZE);

    //设置vcpu-isa
	reg.id = RISCV_CONFIG_REG(isa);
	reg.addr = (unsigned long)&isa;
	if (ioctl(vcpu->vcpu_fd, KVM_SET_ONE_REG, &reg) < 0)
		die("KVM_SET_ONE_REG failed (config.isa)");

    //cpu厂商相关
	if (kvm->cfg.arch.custom_mvendorid) {
		id = kvm->cfg.arch.custom_mvendorid;
		reg.id = RISCV_CONFIG_REG(mvendorid);
		reg.addr = (unsigned long)&id;
		if (ioctl(vcpu->vcpu_fd, KVM_SET_ONE_REG, &reg) < 0)
			die("KVM_SET_ONE_REG failed (config.mvendorid)");
	}

    //设置marchid
	if (kvm->cfg.arch.custom_marchid) {
		id = kvm->cfg.arch.custom_marchid;
		reg.id = RISCV_CONFIG_REG(marchid);
		reg.addr = (unsigned long)&id;
		if (ioctl(vcpu->vcpu_fd, KVM_SET_ONE_REG, &reg) < 0)
			die("KVM_SET_ONE_REG failed (config.marchid)");
	}

    //mimpid
	if (kvm->cfg.arch.custom_mimpid) {
		id = kvm->cfg.arch.custom_mimpid;
		reg.id = RISCV_CONFIG_REG(mimpid);
		reg.addr = (unsigned long)&id;
		if (ioctl(vcpu->vcpu_fd, KVM_SET_ONE_REG, &reg) < 0)
			die("KVM_SET_ONE_REG failed (config.mimpid)");
	}

    //SBI
	for (i = 0; i < KVM_RISCV_SBI_EXT_MAX; i++) {
		if (!kvm->cfg.arch.sbi_ext_disabled[i])
			continue;
		masks[KVM_REG_RISCV_SBI_MULTI_REG(i)] |=
					KVM_REG_RISCV_SBI_MULTI_MASK(i);
	}
	for (i = 0; i <= KVM_REG_RISCV_SBI_MULTI_REG_LAST; i++) {
		if (!masks[i])
			continue;

		reg.id = RISCV_SBI_EXT_REG(KVM_REG_RISCV_SBI_MULTI_DIS, i);
		reg.addr = (unsigned long)&masks[i];
		if (ioctl(vcpu->vcpu_fd, KVM_SET_ONE_REG, &reg) < 0)
			die("KVM_SET_ONE_REG failed (sbi_ext %d)", i);
	}

	/* Force enable SBI debug console if not disabled from command line */
	if (!kvm->cfg.arch.sbi_ext_disabled[KVM_RISCV_SBI_EXT_DBCN]) {
		id = 1;
		reg.id = RISCV_SBI_EXT_REG(KVM_REG_RISCV_SBI_SINGLE,
					   KVM_RISCV_SBI_EXT_DBCN);
		reg.addr = (unsigned long)&id;
		if (ioctl(vcpu->vcpu_fd, KVM_SET_ONE_REG, &reg) < 0)
			pr_warning("KVM_SET_ONE_REG failed (sbi_ext %d)",
				   KVM_RISCV_SBI_EXT_DBCN);
	}

	/* Populate the vcpu structure. */
	vcpu->kvm				= kvm;
	vcpu->cpu_id			= cpu_id;
	vcpu->riscv_isa		 	= isa;
	vcpu->riscv_xlen	 	= __riscv_xlen;
	vcpu->riscv_timebase 	= timebase;
	vcpu->is_running	 	= true;

	return vcpu;
}
```

## 4.2 kvm: 创建/初始化vcpu

### 1) KVM_CREATE_VCPU

![img](https://img2020.cnblogs.com/blog/1771657/202010/1771657-20201011104631898-2017289936.png)

```c
/* kvmtool */
kvm_cpu__arch_init
	+-> vcpu->vcpu_fd = ioctl(kvm->vm_fd, KVM_CREATE_VCPU, cpu_id);
/* kvm */
		+-> kvm_vm_ioctl
            +-> kvm_vm_ioctl_create_vcpu(kvm, arg);
				//riscv架构暂无实现
				+-> kvm_arch_vcpu_precreate(kvm, id);
				+-> kmem_cache_zalloc(kvm_vcpu_cache, GFP_KERNEL_ACCOUNT);
				+-> page = alloc_page(GFP_KERNEL_ACCOUNT | __GFP_ZERO);
					vcpu->run = page_address(page);
				+-> kvm_vcpu_init(vcpu, kvm, id);
					//为该vcpu初始化preempt_notifiers通知，用于在进程切换时执行vcpu的切入切出操作
					+-> preempt_notifier_init
                //单独分析
				+-> kvm_arch_vcpu_create(vcpu);
                    +-> kvm_riscv_vcpu_setup_isa
                    +-> kvm_riscv_vcpu_timer_init
                    +-> kvm_riscv_vcpu_pmu_init
                    +-> kvm_riscv_vcpu_aia_init
                    +-> kvm_riscv_vcpu_sbi_init
                    +-> kvm_riscv_reset_vcpu
				+-> kvm_dirty_ring_alloc(&vcpu->dirty_ring,
					  					id, kvm->dirty_ring_size);
				//为vcpu创建一个匿名inode，向用户态导出vcpu对应的fd操作接口
				+-> create_vcpu_fd(vcpu);
				// 在riscv架构下该函数不做任何处理
				+-> kvm_arch_vcpu_postcreate(vcpu);
					//具有id 0的虚拟CPU是指定的引导CPU。
					//保持所有具有非零id的虚拟CPU处于关机状态，以便可以使用SBI HSM扩展来启动它们。
                    if (vcpu->vcpu_idx != 0)
                       kvm_riscv_vcpu_power_off(vcpu);
				//vcpu创建deugfs接口
				+-> kvm_create_vcpu_debugfs(vcpu);
					+-> debugfs_dentry = debugfs_create_dir(dir_name,
					    								vcpu->kvm->debugfs_dentry);
					+-> debugfs_create_file("pid", 0444, debugfs_dentry, vcpu,
			    							&vcpu_get_pid_fops);
					//riscv架构暂无实现
					+-> kvm_arch_create_vcpu_debugfs(vcpu, debugfs_dentry);
```

`kvm_arch_vcpu_create` 函数用于初始化vcpu，代码如下：

```c
int kvm_arch_vcpu_create(struct kvm_vcpu *vcpu)
{
	int rc;
	struct kvm_cpu_context *cntx;
	struct kvm_vcpu_csr *reset_csr = &vcpu->arch.guest_reset_csr;

	/* Mark this VCPU never ran */
    /*
      将vcpu->arch.ran_atleast_once设置为false，来标记此vcpu尚未运行；
      设置了此vcpu的内存页缓存的GFP_ZERO标志，意味着为该vcpu分配的新页面将填充为0；
      初始化一个位图，用于指示该vcpu的指令集架构的具体特性；
    */
	vcpu->arch.ran_atleast_once = false;
	vcpu->arch.mmu_page_cache.gfp_zero = __GFP_ZERO;
	bitmap_zero(vcpu->arch.isa, RISCV_ISA_EXT_MAX);

	/* Setup ISA features available to VCPU */
    //遍历每个可能的ISA扩展，并检查每个扩展是否可用，如果可用，则设置ISA位图中对应的位；
	kvm_riscv_vcpu_setup_isa(vcpu);

	/* Setup vendor, arch, and implementation details */
   	//发起SBI调用，依次设置vcpu的供应商、架构以及处理器实现版本ID；
	vcpu->arch.mvendorid = sbi_get_mvendorid();
	vcpu->arch.marchid = sbi_get_marchid();
	vcpu->arch.mimpid = sbi_get_mimpid();

	/* Setup VCPU hfence queue */
	spin_lock_init(&vcpu->arch.hfence_lock);

	/* Setup reset state of shadow SSTATUS and HSTATUS CSRs */
	cntx = &vcpu->arch.guest_reset_context;
	cntx->sstatus = SR_SPP | SR_SPIE;
	cntx->hstatus = 0;
	cntx->hstatus |= HSTATUS_VTW;
	cntx->hstatus |= HSTATUS_SPVP;
	cntx->hstatus |= HSTATUS_SPV;

	if (kvm_riscv_vcpu_alloc_vector_context(vcpu, cntx))
		return -ENOMEM;

	/* By default, make CY, TM, and IR counters accessible in VU mode */
	reset_csr->scounteren = 0x7;
	
    //初始化timer、pmu
	/* Setup VCPU timer */
	kvm_riscv_vcpu_timer_init(vcpu);

	/* setup performance monitoring */
	kvm_riscv_vcpu_pmu_init(vcpu);

	/* Setup VCPU AIA */
	rc = kvm_riscv_vcpu_aia_init(vcpu);
	if (rc)
		return rc;

	/*
	 * Setup SBI extensions
	 * NOTE: This must be the last thing to be initialized.
	 */
	kvm_riscv_vcpu_sbi_init(vcpu);

	/* Reset VCPU */
	kvm_riscv_reset_vcpu(vcpu);

	return 0;
}
```

该流程中，会对 `vcpu->arch.guest_reset_csr`  和 `vcpu->arch.guest_reset_context` 进行初始化设置：

* `reset_csr`

  ```c
  /* By default, make CY, TM, and IR counters accessible in VU mode */
  reset_csr->scounteren = 0x7;
  ```

* `cntx`

  ```c
  /* Setup reset state of shadow SSTATUS and HSTATUS CSRs */
  cntx = &vcpu->arch.guest_reset_context;
  cntx->sstatus = SR_SPP | SR_SPIE;
  cntx->hstatus = 0;
  cntx->hstatus |= HSTATUS_VTW;
  cntx->hstatus |= HSTATUS_SPVP;
  cntx->hstatus |= HSTATUS_SPV;
  ```

  设置vcpu的系统寄存器上下文，包括sstatus/hstatus；

    * `sstatus/hstatus`: 为了确保 sret 指令执行后切换到 VS 态，设置 `sstatus.SPP/hstatus.SPV=1`，表示目标处理器模式为 VS mode；
    * `sstatus.SPIE`: 执行 sret 指令后，此值拷贝给 `sstatus.SIE` ，原位域置零，表示 S 态中断使能；
    * `hstatus.VTW=1` 表示虚拟机中执行 WFI 指令，会触发虚拟指令异常；
    * `hstatus.SPVP=1` 表示执行 HLV/HSV 指令，访问的是 VS 态内存地址；

  > 当 V=1 且陷入HS模式时，位 `SPVP`（监管程序先前虚拟特权）被设置为陷阱发生时的标准特权模式，与 `sstatus.SPP` 相同。
  >
  > * 注意，如果在陷阱发生前 V=0，那么在陷阱进入时 `SPVP` 将保持不变。
  > * `SPVP` 同时也控制着由虚拟机加载/存储指令 `HLV`、`HLVX` 和 `HSV` 进行的显式内存访问的有效特权。假设没有 `SPVP`，如果指令 `HLV`、`HLVX` 和 `HSV` 查看的是 `sstatus.SPP` 来确定它们内存访问的有效特权级别，那么即使HU=1，U模式也无法在访问VS-Mode下的虚拟机内存，因为使用 `SRET` 进入U模式总是会将SPP设为0。与SPP不同，SPVP字段在HS模式和U模式之间来回转换时不会受到影响。
  >
  > ---
  >
  > > **关于 `HLV/HSV` 指令**
  >
  > ![image-20240305105500166](https://cdn.jsdelivr.net/gh/MaskerDad/BlogImage@main/202403051055188.png)
  >
  > Hypervisor虚拟机的加载和存储指令仅在M-Mode/HS-Mode中有效，或在当 `hstatus.HU=1` 时在U模式中有效。每条指令执行显式内存访问，就好像V=1的状态，即具有适用于VS/VU模式中的内存访问的地址转换和保护，以及字节序。
  >
  > `hstatus.SPVP` 控制访问的特权级别。
  >
  > * 当 `SPVP=0` 时，显式内存访问就好像在VU模式中进行
  > * 当 `SPVP=1` 时，就好像在VS模式中进行
  >
  > 与通常情况下 V=1 一样，应用了两级地址转换，并且忽略了HS级别的 `sstatus.SUM`。HS级别的 `sstatus.MXR` 使得仅执行页面对地址转换的两个阶段（VS阶段和G阶段）可读，而 `vsstatus.MXR` 仅影响第一个转换阶段（VS阶段）。
  >
  > 当 V=1 时，尝试执行虚拟机加载/存储指令（`HLV`、`HLVX` 或 `HSV`）会导致虚拟指令陷阱。当 `hstatus.HU=0` 且从 U 模式尝试执行这些相同指令之一时，会导致非法指令陷阱。

---

调用 `kvm_riscv_reset_vcpu` 重置vcpu中的寄存器、特权级以及CSR状态，确保vcpu执行虚拟机之前处于一个干净的初始状态；

```c
static void kvm_riscv_reset_vcpu(struct kvm_vcpu *vcpu)
{
	struct kvm_vcpu_csr *csr = &vcpu->arch.guest_csr;
	struct kvm_vcpu_csr *reset_csr = &vcpu->arch.guest_reset_csr;
	struct kvm_cpu_context *cntx = &vcpu->arch.guest_context;
	struct kvm_cpu_context *reset_cntx = &vcpu->arch.guest_reset_context;
	bool loaded;

	/**
	 * The preemption should be disabled here because it races with
	 * kvm_sched_out/kvm_sched_in(called from preempt notifiers) which
	 * also calls vcpu_load/put.
	 */
	get_cpu();
	loaded = (vcpu->cpu != -1);
	if (loaded)
		kvm_arch_vcpu_put(vcpu);

	vcpu->arch.last_exit_cpu = -1;

	memcpy(csr, reset_csr, sizeof(*csr));

	memcpy(cntx, reset_cntx, sizeof(*cntx));

	kvm_riscv_vcpu_fp_reset(vcpu);

	kvm_riscv_vcpu_vector_reset(vcpu);

	kvm_riscv_vcpu_timer_reset(vcpu);

	kvm_riscv_vcpu_aia_reset(vcpu);

	bitmap_zero(vcpu->arch.irqs_pending, KVM_RISCV_VCPU_NR_IRQS);
	bitmap_zero(vcpu->arch.irqs_pending_mask, KVM_RISCV_VCPU_NR_IRQS);

	kvm_riscv_vcpu_pmu_reset(vcpu);

	vcpu->arch.hfence_head = 0;
	vcpu->arch.hfence_tail = 0;
	memset(vcpu->arch.hfence_queue, 0, sizeof(vcpu->arch.hfence_queue));

	kvm_riscv_vcpu_sbi_sta_reset(vcpu);

	/* Reset the guest CSRs for hotplug usecase */
	if (loaded)
		kvm_arch_vcpu_load(vcpu, smp_processor_id());
	put_cpu();
}
```

### //TODO: 2) KVM_GET/SET_ONE_REG

> 关于 `KVM_GET_ONE_REG/KVM_SET_ONE_REG`

https://elixir.bootlin.com/linux/latest/source/Documentation/virt/kvm/api.rst#L2752，硬件上的真实寄存器只有一套，我们需要为在riscv hart上运行的每个vcpu都维护一套独立的状态，同时虚拟机应该和物理机拥有相同的寄存器视图。`KVM_GET_ONE_REG/KVM_SET_ONE_REG` 是KVM提供给用户态工具的获取/设置任意寄存器的接口，这么多寄存器总得有一个flag与每个寄存器进行对应否则怎么区分？这就是 `kvm_one_reg` 的 id 字段，这个 `reg->id` 和硬件架构无关，是KVM纯软件层面的协议，与KVM对接的用户态工具也需要遵循它来写代码。

从kvmtool到kvm的调用链，如下：

```c
/* kvmtool */
struct kvm_one_reg {
	__u64 id;
	__u64 addr;
};

reg.id = RISCV_CONFIG_REG(isa);
reg.addr = (unsigned long)&isa;
if (ioctl(vcpu->vcpu_fd, KVM_GET_ONE_REG, &reg) < 0)
    die("KVM_GET_ONE_REG failed (config.isa)");

#define RISCV_CONFIG_REG(name)	__kvm_reg_id(KVM_REG_RISCV_CONFIG, 0, \
					     KVM_REG_RISCV_CONFIG_REG(name), \
					     KVM_REG_SIZE_ULONG)

//获取vcpu-isa
reg.id = RISCV_CONFIG_REG(isa);
reg.addr = (unsigned long)&isa;
if (ioctl(vcpu->vcpu_fd, KVM_GET_ONE_REG, &reg) < 0)
    die("KVM_GET_ONE_REG failed (config.isa)");

//获取vtime
reg.id = RISCV_TIMER_REG(frequency);
reg.addr = (unsigned long)&timebase;
if (ioctl(vcpu->vcpu_fd, KVM_GET_ONE_REG, &reg) < 0)
    die("KVM_GET_ONE_REG failed (timer.frequency)");
--------------------------------------------------------------------------
#define KVM_REG_RISCV		0x8000000000000000ULL
static inline __u64 __kvm_reg_id(__u64 type, __u64 subtype,
				 __u64 idx, __u64  size)
{
	return KVM_REG_RISCV | type | subtype | idx | size;
}
/* Config registers are mapped as type 1 */
#define KVM_REG_RISCV_CONFIG		(0x01 << KVM_REG_RISCV_TYPE_SHIFT)
#define KVM_REG_RISCV_CONFIG_REG(name)	\
	(offsetof(struct kvm_riscv_config, name) / sizeof(unsigned long))

#define KVM_REG_RISCV_TYPE_SHIFT	24
/* Config registers are mapped as type 1 */
#define KVM_REG_RISCV_CONFIG		(0x01 << KVM_REG_RISCV_TYPE_SHIFT)

kvm_vcpu_ioctl
    +-> case default: kvm_arch_vcpu_ioctl
		+-> KVM_SET_ONE_REG:
			kvm_riscv_vcpu_set_reg(vcpu, &reg);
		+-> KVM_GET_ONE_REG:
			kvm_riscv_vcpu_get_reg(vcpu, &reg);
```

kvmtool对 `isa/timer/sbi` 进行了设置，下面重点关注这三个。

---

https://elixir.bootlin.com/linux/latest/source/Documentation/virt/kvm/api.rst#L2292

#### isa

```c
kvm_riscv_vcpu_get_reg
    +-> case KVM_REG_RISCV_ISA_EXT:
			return kvm_riscv_vcpu_get_reg_isa_ext(vcpu, reg);

kvm_riscv_vcpu_set_reg
    +-> case KVM_REG_RISCV_ISA_EXT:
			return kvm_riscv_vcpu_set_reg_isa_ext(vcpu, reg);
				+-> riscv_vcpu_set_isa_ext_single
```

以KVM_SET_ONE_REG为例，设置单个isa时调用 `riscv_vcpu_set_isa_ext_single`：

```c
static int riscv_vcpu_set_isa_ext_single(struct kvm_vcpu *vcpu,
					 unsigned long reg_num,
					 unsigned long reg_val)
{
	unsigned long host_isa_ext;

	if (reg_num >= KVM_RISCV_ISA_EXT_MAX ||
	    reg_num >= ARRAY_SIZE(kvm_isa_ext_arr))
		return -ENOENT;

    //首先检查KVM是否支持呈现该isa，然后再检查裸机是否支持硬件isa，两者同时满足才能设置给guest
	host_isa_ext = kvm_isa_ext_arr[reg_num];
	if (!__riscv_isa_extension_available(NULL, host_isa_ext))
		return -ENOENT;

	if (reg_val == test_bit(host_isa_ext, vcpu->arch.isa))
		return 0;

    /*
    	当guest启动前，即便上述的isa检查通过，但仍然有些isa不允许kvmtool去设置或取消.
    	比如：KVM_RISCV_ISA_EXT_H，默认返回false，因为kvm不支持嵌套虚拟化，guest vcpu不能
    	呈现出h扩展：	
	*/
	if (!vcpu->arch.ran_atleast_once) {
		/*
		 * All multi-letter extension and a few single letter
		 * extension can be disabled
		 */
		if (reg_val == 1 &&
		    kvm_riscv_vcpu_isa_enable_allowed(reg_num))
			set_bit(host_isa_ext, vcpu->arch.isa);
		else if (!reg_val &&
			 kvm_riscv_vcpu_isa_disable_allowed(reg_num))
			clear_bit(host_isa_ext, vcpu->arch.isa);
		else
			return -EINVAL;
		kvm_riscv_vcpu_fp_reset(vcpu);
	} else {
		return -EBUSY;
	}

	return 0;
}
```

#### timer

```c
kvm_riscv_vcpu_get_reg
    +-> case KVM_REG_RISCV_TIMER:
			return kvm_riscv_vcpu_get_reg_timer(vcpu, reg);

kvm_riscv_vcpu_set_reg
    +-> case KVM_REG_RISCV_TIMER:
			return kvm_riscv_vcpu_set_reg_timer(vcpu, reg);
    
```

[v17,12/17\] RISC-V: KVM: Add timer functionality - Patchwork (kernel.org)](https://patchwork.kernel.org/project/linux-riscv/patch/20210401133435.383959-13-anup.patel@wdc.com/)

#### SBI

```c
kvm_riscv_vcpu_get_reg
    +->	case KVM_REG_RISCV_SBI_EXT:
			return kvm_riscv_vcpu_get_reg_sbi_ext(vcpu, reg);
	+-> case KVM_REG_RISCV_SBI_STATE:
			return kvm_riscv_vcpu_get_reg_sbi(vcpu, reg);

kvm_riscv_vcpu_set_reg
    +-> case KVM_REG_RISCV_SBI_EXT:
			return kvm_riscv_vcpu_set_reg_sbi_ext(vcpu, reg);
				+-> riscv_vcpu_set_sbi_ext_single
	+-> case KVM_REG_RISCV_SBI_STATE:
			return kvm_riscv_vcpu_set_reg_sbi(vcpu, reg);
				+-> case KVM_REG_RISCV_SBI_STA:
						kvm_riscv_vcpu_set_reg_sbi_sta(vcpu, reg_num, reg_val);
```

分别看下，KVM_REG_RISCV_SBI_EXT 和 KVM_REG_RISCV_SBI_STATE：

> **KVM_REG_RISCV_SBI_EXT**

`riscv_vcpu_set_sbi_ext_single` 函数，sbi属于non-isa，和isa的检查以及设置大致一个套路，先检查目前kvm是否支持该sbi_ext，如果支持再获取 `sext->ext_idx` 去设置 `vcpu->arch.sbi_context`。

```c
static int riscv_vcpu_set_sbi_ext_single(struct kvm_vcpu *vcpu,
					 unsigned long reg_num,
					 unsigned long reg_val)
{
	struct kvm_vcpu_sbi_context *scontext = &vcpu->arch.sbi_context;
	const struct kvm_riscv_sbi_extension_entry *sext;

	if (reg_val != 1 && reg_val != 0)
		return -EINVAL;

	sext = riscv_vcpu_get_sbi_ext(vcpu, reg_num);
	if (!sext || scontext->ext_status[sext->ext_idx] 
        		== KVM_RISCV_SBI_EXT_STATUS_UNAVAILABLE)
		return -ENOENT;

	scontext->ext_status[sext->ext_idx] = (reg_val) ?
			KVM_RISCV_SBI_EXT_STATUS_ENABLED :
			KVM_RISCV_SBI_EXT_STATUS_DISABLED;

	return 0;
}

static const struct kvm_riscv_sbi_extension_entry *
riscv_vcpu_get_sbi_ext(struct kvm_vcpu *vcpu, unsigned long idx)
{
	const struct kvm_riscv_sbi_extension_entry *sext = NULL;

	if (idx >= KVM_RISCV_SBI_EXT_MAX)
		return NULL;

	for (int i = 0; i < ARRAY_SIZE(sbi_ext); i++) {
		if (sbi_ext[i].ext_idx == idx) {
			sext = &sbi_ext[i];
			break;
		}
	}

	return sext;
}

struct kvm_riscv_sbi_extension_entry {
	enum KVM_RISCV_SBI_EXT_ID ext_idx;
	const struct kvm_vcpu_sbi_extension *ext_ptr;
};

static const struct kvm_riscv_sbi_extension_entry sbi_ext[] = {
	{
		.ext_idx = KVM_RISCV_SBI_EXT_V01,
		.ext_ptr = &vcpu_sbi_ext_v01,
	},
    //...
}

#ifndef CONFIG_RISCV_SBI_V01
static const struct kvm_vcpu_sbi_extension vcpu_sbi_ext_v01 = {
	.extid_start = -1UL,
	.extid_end = -1UL,
	.handler = NULL,
};
#endif
```

> **KVM_REG_RISCV_SBI_STATE**

上面的KVM_REG_RISCV_SBI_EXT用于 `sbi_ext` 的探测与设置，而这个flag，是用于对某个特定的 `sbi_ext` 的进一步设置，目前仅支持 `KVM_RISCV_SBI_EXT_STA`：

```c
static const struct kvm_riscv_sbi_extension_entry sbi_ext[] = {
    {
		.ext_idx = KVM_RISCV_SBI_EXT_STA,
		.ext_ptr = &vcpu_sbi_ext_sta,
	},
}

int kvm_riscv_vcpu_set_reg_sbi(struct kvm_vcpu *vcpu,
			       const struct kvm_one_reg *reg)
{
	//...
	switch (reg_subtype) {
	case KVM_REG_RISCV_SBI_STA:
		return kvm_riscv_vcpu_set_reg_sbi_sta(vcpu, reg_num, reg_val);
	default:
		return -EINVAL;
	}

	return 0;
}
```

### 2) MMIO

> 关于 `KVM_CAP_COALESCED_MMIO`

"coalesced_memory" 这种方式所仿真的 MMIO 会被 KVM 内核截取，但 KVM 并不会立即跳出到 qemu-kvm 用户空间，KVM 将需要仿真的读写操作形成一个记录 (`struct kvm_coalesced_mmio`)， 放在在代表整个VM的 `struct kvm` 所指向的一个环形缓冲区中 ( `struct kvm_coalesced_mmio_ring`)， 这个环形缓冲区被 mmap 到了用户空间。 

当下一次代表某个 VCPU 的 qemu-kvm 线程返回到用户空间后，就会对环形缓冲区中的记录进行处理，执行 MMIO 读写仿真。 也就是说，对于 “coalesced_memory” 方式， qemu-kvm 一次仿真的可能是已经被积累起来的多个 MMIO 读写操作， 显然这种方式是一种性能优化，它适合于对响应时间要求不严格的 MMIO 写操作。

# 5 vCPU运行

在kvmtool主流程中，该阶段的位置：

```c
kvm_cmd_run_work(kvm)
    //vcpu准备、运行、退出处理
    +-> for (i = 0; i < kvm->nrcpus; i++) {
            if (pthread_create(&kvm->cpus[i]->thread, NULL, 
                               	kvm_cpu_thread, kvm->cpus[i]) != 0)
            die("unable to create KVM VCPU thread");
        }
    	//...
    	return kvm_cpu__exit(kvm); 
    --------------------------------
        /* vcpu启动线程：kvm_cpu_thread */
        kvm_cpu_thread
       	+-> kvm_cpu__start(current_kvm_cpu)
        	//ioctl(KVM_GET_MP_STATE)，将kernel/DTB的hva地址传递给KVM
        	+-> kvm_cpu__reset_vcpu 
        	+-> kvm_cpu__run
        		+-> ioctl(vcpu->vcpu_fd, KVM_RUN, 0);
			while (cpu->is_running)
            +-> switch (cpu->kvm_run->exit_reason) 
                +-> KVM_EXIT_DEBUG:
            		kvm_cpu__show_registers(cpu);
            		kvm_cpu__show_code(cpu);
            	+-> KVM_EXIT_IO:
           		    ret = kvm_cpu__emulate_io(cpu,
                                              cpu->kvm_run->io.port,
                                              (u8 *)cpu->kvm_run +
                                              cpu->kvm_run->io.data_offset,
                                              cpu->kvm_run->io.direction,
                                              cpu->kvm_run->io.size,
                                              cpu->kvm_run->io.count);
            	+-> KVM_EXIT_MMIO:
            		kvm_cpu__handle_coalesced_mmio(cpu);
            		ret = kvm_cpu__emulate_mmio(cpu,
                                        cpu->kvm_run->mmio.phys_addr,
                                        cpu->kvm_run->mmio.data,
                                        cpu->kvm_run->mmio.len,
                                        cpu->kvm_run->mmio.is_write);
kvm_cmd_run_exit(kvm, ret) // 执行各种deinit
	+-> compat__print_all_messages();
	+-> init_list__exit(kvm);
```

## 5.1 kvmtool: vcpu运行

在 `init_list__init` 执行完所有初始化函数后, 会一路返回到 `kvm_cmd_run()` 中, 进入 `kvm_cmd_run_work()` 开始虚拟机的执行：

```c
int kvm_cmd_run(int argc, const char** argv, const char* prefix)
{
    int ret = -EFAULT;
    struct kvm* kvm;

    //根据参数初始化一个kvm对象
    kvm = kvm_cmd_run_init(argc, argv);
    //执行一个虚拟机
    ret = kvm_cmd_run_work(kvm);
    //虚拟机退出
    kvm_cmd_run_exit(kvm, ret);
    return ret;
}
```

`kvm_cmd_run_work()` 为每一个vcpu创建一个线程并开始执行，然后等待 `CPU #0` 执行完毕, 至此kvmtool主线程挂起, 变成多个vcpu线程执行：

```c
static int kvm_cmd_run_work(struct kvm *kvm)
{
	int i;
	
    //为每一个vcpu创建一个线程, 执行kvm_cpu_thread(kvm->cpus[i])
	for (i = 0; i < kvm->nrcpus; i++) {
		if (pthread_create(&kvm->cpus[i]->thread, NULL, 
                           kvm_cpu_thread, kvm->cpus[i]) != 0)
			die("unable to create KVM VCPU thread");
	}

	/* Only VCPU #0 is going to exit by itself when shutting down */
    //关机时只有VCPU #0会自己退出, 因此只需要等待这一个线程即可
	if (pthread_join(kvm->cpus[0]->thread, NULL) != 0)
		die("unable to join with vcpu 0");

	return kvm_cpu__exit(kvm);
}
```

`kvm_cpu_thread` 在设置线程名后，调用 `kvm_cpu__start` 开始vcpu的执行，整体上是一个 `trap-emul` 循环：

```c
int kvm_cpu__start(struct kvm_cpu* cpu)
{
    sigset_t sigset;

    ...;    //信号处理相关

    //重置CPU状态
    kvm_cpu__reset_vcpu(cpu);
    
    //CPU循环
    while (cpu->is_running) {
        //通知KVM开始cpu的执行
        kvm_cpu__run(cpu);

        //处理虚拟机退出原因
        switch (cpu->kvm_run->exit_reason) {
            case KVM_EXIT_IO: { //因为IO端口引发的vmexit
                ...;
            }
            case KVM_EXIT_MMIO: {
                ...;
            }
            case ...;
        }
        kvm_cpu__handle_coalesced_mmio(cpu);
    }
exit_kvm:
    return 0;
}
```

`kvm_cpu__start` 初始化vcpu寄存器后，会调用 `kvm_cpu__run` 函数开启vcpu的运行，该函数会通过 `ioctl(vcpu->vcpu_fd, KVM_RUN, 0)`通知KVM开始运行vcpu, KVM随后通过 `sret` 指令切入Guest, 而 `ioctl(KVM_RUN, ...)` 会被一直阻塞, 直到必须由kvmtool介入为止 (因为有些VM_EXIT在内核中就可以处理)，而后kvmtool会处理虚拟机退出, 然后继续开始vcpu的运行。

```c
void kvm_cpu__run(struct kvm_cpu* vcpu)
{
    int err;
    if (!vcpu->is_running)
        return;
    err = ioctl(vcpu->vcpu_fd, KVM_RUN, 0);
    if (err < 0 && (errno != EINTR && errno != EAGAIN))
        die_perror("KVM_RUN failed");
}
```

---

之前在 `kvm_cpu__arch_init` 函数中设置了一些基本vcpu寄存器，在vcpu运行这部分代码中也会进行一些vcpu寄存器设置工作，具体在 `kvm_vcpu__reset_vcpu` 函数中，主要是pc、a0、a1寄存器，分别被赋值为虚拟机内核初始执行地址、启动核hart_id、虚拟机dtb地址。

```c
void kvm_cpu__reset_vcpu(struct kvm_cpu *vcpu)
{
	struct kvm *kvm = vcpu->kvm;
	struct kvm_mp_state mp_state;
	struct kvm_one_reg reg;
	unsigned long data;

	if (ioctl(vcpu->vcpu_fd, KVM_GET_MP_STATE, &mp_state) < 0)
		die_perror("KVM_GET_MP_STATE failed");

    /*
     * 如果MP状态为停止，那么这意味着Linux KVM RISC-V模拟了
     * SBI v0.2（或更高版本）的HART电源管理，并且指定的VCPU
     * 将在启动时由引导VCPU进行启动。对于这样的VCPU，我们
     * 不在这里更新PC, A0和A1。？？？
     */
	if (mp_state.mp_state == KVM_MP_STATE_STOPPED)
		return;

	reg.addr = (unsigned long)&data;

	data	= kvm->arch.kern_guest_start;
	reg.id	= RISCV_CORE_REG(regs.pc);
	if (ioctl(vcpu->vcpu_fd, KVM_SET_ONE_REG, &reg) < 0)
		die_perror("KVM_SET_ONE_REG failed (pc)");

	data	= vcpu->cpu_id;
	reg.id	= RISCV_CORE_REG(regs.a0);
	if (ioctl(vcpu->vcpu_fd, KVM_SET_ONE_REG, &reg) < 0)
		die_perror("KVM_SET_ONE_REG failed (a0)");

	data	= kvm->arch.dtb_guest_start;
	reg.id	= RISCV_CORE_REG(regs.a1);
	if (ioctl(vcpu->vcpu_fd, KVM_SET_ONE_REG, &reg) < 0)
		die_perror("KVM_SET_ONE_REG failed (a1)");
}
```

* `KVM_GET_MP_STATE`

  > [Documentation](https://elixir.bootlin.com/linux/latest/source/Documentation)/[virt](https://elixir.bootlin.com/linux/latest/source/Documentation/virt)/[kvm](https://elixir.bootlin.com/linux/latest/source/Documentation/virt/kvm)/[api.rst](https://elixir.bootlin.com/linux/latest/source/Documentation/virt/kvm/api.rst)
  >
  > For riscv:
  > ^^^^^^^^^^
  >
  > The only states that are valid are KVM_MP_STATE_STOPPED and
  > KVM_MP_STATE_RUNNABLE which reflect if the vcpu is paused or not.

  ```c
  int kvm_arch_vcpu_ioctl_get_mpstate(struct kvm_vcpu *vcpu,
  				    struct kvm_mp_state *mp_state)
  {
  	if (vcpu->arch.power_off)
  		mp_state->mp_state = KVM_MP_STATE_STOPPED;
  	else
  		mp_state->mp_state = KVM_MP_STATE_RUNNABLE;
  
  	return 0;
  }
  ```

## 5.2 kvm: vcpu运行

![](https://cdn.jsdelivr.net/gh/MaskerDad/BlogImage@main/kvm%E4%B8%ADvcpu%E8%BF%90%E8%A1%8C.png)

kvmtool通过 `KVM_RUN` ioctl，触发 `kvm_arch_vcpu_ioctl_run` 函数的执行：

```c
int kvm_arch_vcpu_ioctl_run(struct kvm_vcpu *vcpu)
{
	int ret;
	struct kvm_cpu_trap trap;
	struct kvm_run *run = vcpu->run;

	if (!vcpu->arch.ran_atleast_once)
		kvm_riscv_vcpu_setup_config(vcpu);

	/* Mark this VCPU ran at least once */
	vcpu->arch.ran_atleast_once = true;

	kvm_vcpu_srcu_read_lock(vcpu);

	switch (run->exit_reason) {
	case KVM_EXIT_MMIO:
		/* Process MMIO value returned from user-space */
		ret = kvm_riscv_vcpu_mmio_return(vcpu, vcpu->run);
		break;
	case KVM_EXIT_RISCV_SBI:
		/* Process SBI value returned from user-space */
		ret = kvm_riscv_vcpu_sbi_return(vcpu, vcpu->run);
		break;
	case KVM_EXIT_RISCV_CSR:
		/* Process CSR value returned from user-space */
		ret = kvm_riscv_vcpu_csr_return(vcpu, vcpu->run);
		break;
	default:
		ret = 0;
		break;
	}
	if (ret) {
		kvm_vcpu_srcu_read_unlock(vcpu);
		return ret;
	}

	if (run->immediate_exit) {
		kvm_vcpu_srcu_read_unlock(vcpu);
		return -EINTR;
	}

	vcpu_load(vcpu);

	kvm_sigset_activate(vcpu);

	ret = 1;
	run->exit_reason = KVM_EXIT_UNKNOWN;
	while (ret > 0) {
		/* Check conditions before entering the guest */
		ret = xfer_to_guest_mode_handle_work(vcpu);
		if (ret)
			continue;
		ret = 1;

		kvm_riscv_gstage_vmid_update(vcpu);

		kvm_riscv_check_vcpu_requests(vcpu);

		preempt_disable();

		/* Update AIA HW state before entering guest */
		ret = kvm_riscv_vcpu_aia_update(vcpu);
		if (ret <= 0) {
			preempt_enable();
			continue;
		}

		local_irq_disable();

		/*
		 * Ensure we set mode to IN_GUEST_MODE after we disable
		 * interrupts and before the final VCPU requests check.
		 * See the comment in kvm_vcpu_exiting_guest_mode() and
		 * Documentation/virt/kvm/vcpu-requests.rst
		 */
		vcpu->mode = IN_GUEST_MODE;

		kvm_vcpu_srcu_read_unlock(vcpu);
		smp_mb__after_srcu_read_unlock();

		/*
		 * We might have got VCPU interrupts updated asynchronously
		 * so update it in HW.
		 */
		kvm_riscv_vcpu_flush_interrupts(vcpu);

		/* Update HVIP CSR for current CPU */
		kvm_riscv_update_hvip(vcpu);

		if (kvm_riscv_gstage_vmid_ver_changed(&vcpu->kvm->arch.vmid) ||
		    kvm_request_pending(vcpu) ||
		    xfer_to_guest_mode_work_pending()) {
			vcpu->mode = OUTSIDE_GUEST_MODE;
			local_irq_enable();
			preempt_enable();
			kvm_vcpu_srcu_read_lock(vcpu);
			continue;
		}

		/*
		 * Cleanup stale TLB enteries
		 *
		 * Note: This should be done after G-stage VMID has been
		 * updated using kvm_riscv_gstage_vmid_ver_changed()
		 */
		kvm_riscv_local_tlb_sanitize(vcpu);

		guest_timing_enter_irqoff();

		kvm_riscv_vcpu_enter_exit(vcpu);

		vcpu->mode = OUTSIDE_GUEST_MODE;
		vcpu->stat.exits++;

		/*
		 * Save SCAUSE, STVAL, HTVAL, and HTINST because we might
		 * get an interrupt between __kvm_riscv_switch_to() and
		 * local_irq_enable() which can potentially change CSRs.
		 */
		trap.sepc = vcpu->arch.guest_context.sepc;
		trap.scause = csr_read(CSR_SCAUSE);
		trap.stval = csr_read(CSR_STVAL);
		trap.htval = csr_read(CSR_HTVAL);
		trap.htinst = csr_read(CSR_HTINST);

		/* Syncup interrupts state with HW */
		kvm_riscv_vcpu_sync_interrupts(vcpu);

		/*
		 * We must ensure that any pending interrupts are taken before
		 * we exit guest timing so that timer ticks are accounted as
		 * guest time. Transiently unmask interrupts so that any
		 * pending interrupts are taken.
		 *
		 * There's no barrier which ensures that pending interrupts are
		 * recognised, so we just hope that the CPU takes any pending
		 * interrupts between the enable and disable.
		 */
		local_irq_enable();
		local_irq_disable();

		guest_timing_exit_irqoff();

		local_irq_enable();

		preempt_enable();

		kvm_vcpu_srcu_read_lock(vcpu);

		ret = kvm_riscv_vcpu_exit(vcpu, run, &trap);
	}

	kvm_sigset_deactivate(vcpu);

	vcpu_put(vcpu);

	kvm_vcpu_srcu_read_unlock(vcpu);

	return ret;
}
```

以上是kvm-riscv中vcpu运行的最核心的一段代码，涉及到的子模块很多，包括timer、irq、fp/vector、vmid、exit_handler等，暂时不考虑同步问题，按照kvm功能，拆解成若干部分进行分析，大致列举出来：

* `process value returned from user-space`：对从用户态返回的MMIO/SBI/CSR值，进行同步处理；
* `vcpu_load/vcpu_put`：vcpu涉及的host/guest上下文保存与恢复；
* `vcpu_run core loop`：vcpu运行切入guset，所在的核心循环流程
  * `vpu-request`
  * `local_irq/preempt_enable/disable`
  * `interrupt flush/update/sync`
  * `kvm_riscv_vcpu_enter_exit`
  * `kvm_riscv_vcpu_exit`：不在本节分析；
  * `vmid update`：不在本节分析；

### 1) process value returned from user-space

```c
switch (run->exit_reason) {
    case KVM_EXIT_MMIO:
        /* Process MMIO value returned from user-space */
        ret = kvm_riscv_vcpu_mmio_return(vcpu, vcpu->run);
        break;
    case KVM_EXIT_RISCV_SBI:
        /* Process SBI value returned from user-space */
        ret = kvm_riscv_vcpu_sbi_return(vcpu, vcpu->run);
        break;
    case KVM_EXIT_RISCV_CSR:
        /* Process CSR value returned from user-space */
        ret = kvm_riscv_vcpu_csr_return(vcpu, vcpu->run);
        break;
    default:
        ret = 0;
        break;
}
```

#### `kvm_riscv_vcpu_mmio_return` 

https://elixir.bootlin.com/linux/v6.9-rc6/C/ident/kvm_riscv_vcpu_mmio_return

解析MMIO指令，分支处理 `run->mmio.data`，结果保存在 `vcpu->arch.guest_context` 中。

#### `kvm_riscv_vcpu_sbi_return`

https://elixir.bootlin.com/linux/v6.9-rc6/C/ident/kvm_riscv_vcpu_sbi_return

```c
int kvm_riscv_vcpu_sbi_return(struct kvm_vcpu *vcpu, struct kvm_run *run)
{
	struct kvm_cpu_context *cp = &vcpu->arch.guest_context;

	/* Handle SBI return only once */
	if (vcpu->arch.sbi_context.return_handled)
		return 0;
	vcpu->arch.sbi_context.return_handled = 1;

	/* Update return values */
	cp->a0 = run->riscv_sbi.ret[0];
	cp->a1 = run->riscv_sbi.ret[1];

	/* Move to next instruction */
	vcpu->arch.guest_context.sepc += 4;

	return 0;
}
```

---

[PATCH v11 kvmtool 7/8\] riscv: Handle SBI calls forwarded to user space - Anup Patel (kernel.org)](https://lore.kernel.org/all/20211119124515.89439-8-anup.patel@wdc.com/)

对于VS mode下的guset os发起的sbi_call，一般由kvm去模拟，还有一些sbi_call需要退出到kvmtool，也就是由host user从U mode请求SBI服务：

```c
static bool kvm_cpu_riscv_sbi(struct kvm_cpu *vcpu)
{
	//...

	switch (vcpu->kvm_run->riscv_sbi.extension_id) {
	case SBI_EXT_0_1_CONSOLE_PUTCHAR:
		ch = vcpu->kvm_run->riscv_sbi.args[0];
		term_putc(&ch, 1, 0);
		vcpu->kvm_run->riscv_sbi.ret[0] = 0;
		break;
	case SBI_EXT_0_1_CONSOLE_GETCHAR:
		if (term_readable(0))
			vcpu->kvm_run->riscv_sbi.ret[0] =
					term_getc(vcpu->kvm, 0);
		else
			vcpu->kvm_run->riscv_sbi.ret[0] = SBI_ERR_FAILURE;
		break;
    }
    
    //...
}
```

内核的kvm-riscv模块，将转发某些SBI调用到用户空间。这些转发的SBI调用，通常是无法在内核空间中模拟的SBI调用，例如PUTCHAR和GETCHAR调用。

#### `kvm_riscv_vcpu_csr_return`

https://elixir.bootlin.com/linux/v6.9-rc6/C/ident/kvm_riscv_vcpu_csr_return

```c
int kvm_riscv_vcpu_csr_return(struct kvm_vcpu *vcpu, struct kvm_run *run)
{
	ulong insn;

	if (vcpu->arch.csr_decode.return_handled)
		return 0;
	vcpu->arch.csr_decode.return_handled = 1;

	/* Update destination register for CSR reads */
	insn = vcpu->arch.csr_decode.insn;
	if ((insn >> SH_RD) & MASK_RX)
		SET_RD(insn, &vcpu->arch.guest_context,
		       run->riscv_csr.ret_value);

	/* Move to next instruction */
	vcpu->arch.guest_context.sepc += INSN_LEN(insn);

	return 0;
}
```

---

> **kvmtool对某些CSR的模拟：**

[[kvmtool PATCH v2 04/10\] riscv: Add scalar crypto extensions support - Anup Patel (kernel.org)](https://lore.kernel.org/all/20240325153141.6816-5-apatel@ventanamicro.com/)

当标量扩展可用时，通过设备树将其暴露给客户端，以便guest可以使用它们。这包括 Zbkb、Zbkc、Zbkx、Zknd、Zkne、Zknh、Zkr、Zksed、Zksh 和 Zkt 扩展。

Zkr 扩展需要在用户空间进行 SEED CSR 模拟，因此我们还添加相关的 KVM_EXIT_RISCV_CSR 处理。

```c
static bool kvm_cpu_riscv_csr(struct kvm_cpu *vcpu)
{
	int dfd = kvm_cpu__get_debug_fd();
	bool ret = true;

	switch (vcpu->kvm_run->riscv_csr.csr_num) {
	case CSR_SEED:
		/*
		 * We ignore the new_value and write_mask and simply
		 * return a random value as SEED.
		 */
		vcpu->kvm_run->riscv_csr.ret_value = SEED_OPST_ES16;
		vcpu->kvm_run->riscv_csr.ret_value |= rand() & SEED_ENTROPY_MASK;
		break;
	//...
	}

	return ret;
}
```

> **对于KVM_EXIT_RISCV_CSR：**

这种场景，通常是kvm guest在VS mode下，执行某些指令时触发了EXC_VIRTUAL_INST_FAULT (见 `6.2`)，kvm会根据 `stval` 判断指令类型，然后进行分支处理，大致如下：

```c
kvm_riscv_vcpu_virtual_insn
	+-> truly_illegal_insn
	+-> system_opcode_insn
    	+-> ifn = &system_opcode_funcs[i];
			ifn->func(vcpu, run, insn);

static const struct insn_func system_opcode_funcs[] = {
	{
		.mask  = INSN_MASK_CSRRW,
		.match = INSN_MATCH_CSRRW,
		.func  = csr_insn,
	},
    //...
    {
		.mask  = INSN_MASK_WFI,
		.match = INSN_MATCH_WFI,
		.func  = wfi_insn,
	},
}

static int csr_insn(struct kvm_vcpu *vcpu, struct kvm_run *run, ulong insn)
{
    /* Decode the CSR instruction */ 
    /* Save instruction decode info */
    /* Update CSR details in kvm_run struct */
       
   	/* Find in-kernel CSR function */
	for (i = 0; i < ARRAY_SIZE(csr_funcs); i++) {
		tcfn = &csr_funcs[i];
		if ((tcfn->base <= csr_num) &&
		    (csr_num < (tcfn->base + tcfn->count))) {
			cfn = tcfn;
			break;
		}
	}

	/* First try in-kernel CSR emulation */
	if (cfn && cfn->func) {
		rc = cfn->func(vcpu, csr_num, &val, new_val, wr_mask);
		if (rc > KVM_INSN_EXIT_TO_USER_SPACE) {
			if (rc == KVM_INSN_CONTINUE_NEXT_SEPC) {
				run->riscv_csr.ret_value = val;
				vcpu->stat.csr_exit_kernel++;
				kvm_riscv_vcpu_csr_return(vcpu, run);
				rc = KVM_INSN_CONTINUE_SAME_SEPC;
			}
			return rc;
		}
	}

	/* Exit to user-space for CSR emulation */
	if (rc <= KVM_INSN_EXIT_TO_USER_SPACE) {
		vcpu->stat.csr_exit_user++;
		run->exit_reason = KVM_EXIT_RISCV_CSR;
	}

	return rc;
}

static const struct csr_func csr_funcs[] = {
	KVM_RISCV_VCPU_AIA_CSR_FUNCS
	KVM_RISCV_VCPU_HPMCOUNTER_CSR_FUNCS
	{ .base = CSR_SEED, .count = 1, .func = seed_csr_rmw },
};
```

[3/3\] RISC-V: KVM: Add extensible CSR emulation framework - Patchwork (kernel.org)](https://patchwork.kernel.org/project/linux-riscv/patch/20220610050555.288251-4-apatel@ventanamicro.com/)

我们添加了一个基于现有系统指令模拟的可扩展CSR模拟框架。这将对即将推出的AIA、PMU、嵌套和其他虚拟化功能非常有用。

CSR模拟框架，还提供了在用户空间中模拟CSR的方法，但这仅在非常特定的情况下才会使用，例如：在用户空间中进行AIA IMSIC CSR模拟或供应商特定CSR模拟。

默认情况下，所有未由KVM RISC-V处理的CSR，将作为非法指令陷阱重定向回Guest VCPU。

### 2) vcpu_load/put

```c
/*
 * Switches to specified vcpu, until a matching vcpu_put()
 */
void vcpu_load(struct kvm_vcpu *vcpu)
{
	int cpu = get_cpu();

	__this_cpu_write(kvm_running_vcpu, vcpu);
	preempt_notifier_register(&vcpu->preempt_notifier); //1
	kvm_arch_vcpu_load(vcpu, cpu);						//2
	put_cpu();
}
EXPORT_SYMBOL_GPL(vcpu_load);

void kvm_arch_vcpu_load(struct kvm_vcpu *vcpu, int cpu)
{
	struct kvm_vcpu_csr *csr = &vcpu->arch.guest_csr;

	csr_write(CSR_VSSTATUS, csr->vsstatus);
	csr_write(CSR_VSIE, csr->vsie);
	csr_write(CSR_VSTVEC, csr->vstvec);
	csr_write(CSR_VSSCRATCH, csr->vsscratch);
	csr_write(CSR_VSEPC, csr->vsepc);
	csr_write(CSR_VSCAUSE, csr->vscause);
	csr_write(CSR_VSTVAL, csr->vstval);
	csr_write(CSR_HVIP, csr->hvip);
	csr_write(CSR_VSATP, csr->vsatp);

	kvm_riscv_gstage_update_hgatp(vcpu);

	kvm_riscv_vcpu_timer_restore(vcpu);

	kvm_riscv_vcpu_host_fp_save(&vcpu->arch.host_context);
	kvm_riscv_vcpu_guest_fp_restore(&vcpu->arch.guest_context,
					vcpu->arch.isa);

	vcpu->cpu = cpu;
}
```

1. 将 vcpu 的 `preempt_notifiers` 通知注册到线程的 task 结构体中，用于 host os 对 vcpu 线程的调度；
2. 为 vcpu 运行准备相关的硬件环境，包括 `vtimer` 初始化、`fp` 寄存器上下文切换、**VS 态系统寄存器的加载**等；

---

```c
void vcpu_put(struct kvm_vcpu *vcpu)
{
	preempt_disable();
	kvm_arch_vcpu_put(vcpu);								//1
	preempt_notifier_unregister(&vcpu->preempt_notifier);	//2
	__this_cpu_write(kvm_running_vcpu, NULL);
	preempt_enable();
}
EXPORT_SYMBOL_GPL(vcpu_put);

void kvm_arch_vcpu_put(struct kvm_vcpu *vcpu)
{
	struct kvm_vcpu_csr *csr = &vcpu->arch.guest_csr;

	vcpu->cpu = -1;

	kvm_riscv_vcpu_guest_fp_save(&vcpu->arch.guest_context,
				     vcpu->arch.isa);
	kvm_riscv_vcpu_host_fp_restore(&vcpu->arch.host_context);

	csr->vsstatus = csr_read(CSR_VSSTATUS);
	csr->vsie = csr_read(CSR_VSIE);
	csr->vstvec = csr_read(CSR_VSTVEC);
	csr->vsscratch = csr_read(CSR_VSSCRATCH);
	csr->vsepc = csr_read(CSR_VSEPC);
	csr->vscause = csr_read(CSR_VSCAUSE);
	csr->vstval = csr_read(CSR_VSTVAL);
	csr->hvip = csr_read(CSR_HVIP);
	csr->vsatp = csr_read(CSR_VSATP);
}
```

1. 该函数是 `kvm_vcpu_arch_load` 的逆操作，包括 `fp` 寄存器上下文切换、**VS 态系统寄存器的保存**等；
2. 因为已经从 guest 返回到 host，此后 host os 调度就不需要关注 vcpu 线程的 guest 上下文了；

### 3) vcpu_run core loop

#### a. vcpu-request

```c
int kvm_arch_vcpu_ioctl_run(struct kvm_vcpu *vcpu)
{
    //...
    
    while (ret > 0) {
		/* Check conditions before entering the guest */
		ret = xfer_to_guest_mode_handle_work(vcpu);
		if (ret)
			continue;
		ret = 1;

		kvm_riscv_check_vcpu_requests(vcpu);
    }
    
    //...
}
```

`xfer_to_guest_mode_handle_work`  

> 进入或退出客户模式与系统调用非常相似。从主机内核的角度看，当进入客户时，CPU进入用户空间，退出时返回内核。
>
> kvm_guest_enter_irqoff()是exit_to_user_mode()的KVM特定变体，而kvm_guest_exit_irqoff()是enter_from_user_mode()的KVM变体。状态操作具有相同的顺序。
>
> 任务工作处理在vcpu_run()循环的边界处单独为客户进行，通过xfer_to_guest_mode_handle_work()执行，这是返回到用户空间时处理的工作的子集。
>
> 请勿嵌套KVM进入/退出转换，因为这样做是荒谬的。

---

`kvm_riscv_check_vcpu_requests` :

[vcpu-requests.rst - Documentation/virt/kvm/vcpu-requests.rst - Linux source code (v6.8.9) - Bootlin](https://elixir.bootlin.com/linux/latest/source/Documentation/virt/kvm/vcpu-requests.rst)

```c
static void kvm_riscv_check_vcpu_requests(struct kvm_vcpu *vcpu)
{
	struct rcuwait *wait = kvm_arch_vcpu_get_wait(vcpu);

	if (kvm_request_pending(vcpu)) {
		if (kvm_check_request(KVM_REQ_SLEEP, vcpu)) {
			kvm_vcpu_srcu_read_unlock(vcpu);
            
            //放入阻塞队列中，等待rcuwait_wak_up唤醒vcpu
			rcuwait_wait_event(wait,
				(!vcpu->arch.power_off) && (!vcpu->arch.pause),
				TASK_INTERRUPTIBLE);
			kvm_vcpu_srcu_read_lock(vcpu);

			if (vcpu->arch.power_off || vcpu->arch.pause) {
				/*
				 * Awaken to handle a signal, request to
				 * sleep again later.
				 */
				kvm_make_request(KVM_REQ_SLEEP, vcpu);
			}
		}

		if (kvm_check_request(KVM_REQ_VCPU_RESET, vcpu))
			kvm_riscv_reset_vcpu(vcpu);

		//...
	}
}
```

kvm利用 `KVM_REQ_VCPU_*` 进行vcpu间通信，这种方式比较灵活，vcpu可以在进入core loop之前进行make request，vcpu也可以给其它vcpu_x进行make request，这种方式可能会紧接着调用 `kvm_vcpu_kick` 发送ipi，让target vcpu强制陷出并处理request。无论怎样，core loop内部将调用 `kvm_riscv_check_vcpu_requests` 在切入guest前，处理所有挂起的request。以上两种情况，分别举个例子：

1. **vcpu给自己make request**

   ```c
   int kvm_arch_vcpu_ioctl_run(struct kvm_vcpu *vcpu)
   {
       vcpu_load(vcpu);
       while(ret > 0) {
           kvm_riscv_check_vcpu_requests(vcpu);
           kvm_riscv_vcpu_enter_exit(vcpu);
           //...
   	}
   }
   
   void kvm_arch_vcpu_load(struct kvm_vcpu *vcpu, int cpu)
   {
   	struct kvm_vcpu_csr *csr = &vcpu->arch.guest_csr;
   	struct kvm_vcpu_config *cfg = &vcpu->arch.cfg;
   
   	//...
   
   	kvm_make_request(KVM_REQ_STEAL_UPDATE, vcpu);
   }
   ```

2. **vcpu给其它target vcpu进行make request**

   vcpu处于sleep状态，调用 `rcuwait_wake_up` 唤醒。

   ```c
   static int kvm_sbi_hsm_vcpu_start(struct kvm_vcpu *vcpu)
   {
   	struct kvm_cpu_context *reset_cntx;
   	struct kvm_cpu_context *cp = &vcpu->arch.guest_context;
   	struct kvm_vcpu *target_vcpu;
   	unsigned long target_vcpuid = cp->a0;
       
   	target_vcpu = kvm_get_vcpu_by_id(vcpu->kvm, target_vcpuid);
   	
       kvm_make_request(KVM_REQ_VCPU_RESET, target_vcpu);
   
   	kvm_riscv_vcpu_power_on(target_vcpu);
   
   	return 0;
   }
   
   void kvm_riscv_vcpu_power_on(struct kvm_vcpu *vcpu)
   {
   	vcpu->arch.power_off = false;
   	kvm_vcpu_wake_up(vcpu);
   }
   
   static inline bool __kvm_vcpu_wake_up(struct kvm_vcpu *vcpu)
   {
   	return !!rcuwait_wake_up(kvm_arch_vcpu_get_wait(vcpu));
   }
   ```

   ---

   建立gstage映射后需要刷新tlb，可以指定一个hart_mask，发送ipi中断强制这些vcpu陷出，`sbi_ipi_init` 中分配了MSWI对应的virq，并注册了 `ipi_send_mask` 为一个SBI请求。

   ```c
   kvm_riscv_hfence_gvma_vmid_all_process
       +-> kvm_riscv_local_hfence_gvma_vmid_all
   
   //刷新vcpu tlb的调用链如下
   kvm_vm_ioctl_set_memory_region
   	+-> kvm_set_memory_region  
   		+-> __kvm_set_memory_region
   			+-> kvm_set_memslot
       			+-> kvm_prepare_memory_region
       				+-> kvm_arch_prepare_memory_region
   						+-> kvm_riscv_gstage_ioremap    
   							+-> gstage_set_pte
       							+-> gstage_remote_tlb_flush
   									+-> kvm_riscv_hfence_gvma_vmid_gpa
       									+-> make_xfence_request(kvm, hbase, hmask,
                                                   KVM_REQ_HFENCE,
   			    								KVM_REQ_HFENCE_GVMA_VMID_ALL, &data);
   											+-> kvm_make_vcpus_request_mask
   
   bool kvm_make_vcpus_request_mask(struct kvm *kvm, unsigned int req,
   				 unsigned long *vcpu_bitmap)
   {
   	struct kvm_vcpu *vcpu;
   	struct cpumask *cpus;
   	int i, me;
   	bool called;
   
   	me = get_cpu();
   
   	cpus = this_cpu_cpumask_var_ptr(cpu_kick_mask);
   	cpumask_clear(cpus);
   
   	for_each_set_bit(i, vcpu_bitmap, KVM_MAX_VCPUS) {
   		vcpu = kvm_get_vcpu(kvm, i);
   		if (!vcpu)
   			continue;
   		kvm_make_vcpu_request(vcpu, req, cpus, me);
   	}
   
   	called = kvm_kick_many_cpus(cpus, !!(req & KVM_REQUEST_WAIT));
   	put_cpu();
   
   	return called;
   }
   
   kvm_kick_many_cpus
       +-> smp_call_function_many
       	+-> smp_call_function_many_cond
   			+-> send_call_function_single_ipi
       			+-> arch_send_call_function_single_ipi
       				+-> send_ipi_single
       					+-> __ipi_send_mask
       						struct irq_data *data = irq_desc_get_irq_data(desc);
   							struct irq_chip *chip = irq_data_get_irq_chip(data);
                               if (chip->ipi_send_mask) {
                                   chip->ipi_send_mask(data, dest);
                                   return 0;
                               }
   
   static const struct irq_chip ipi_mux_chip = {
   	.name		= "IPI Mux",
   	.irq_mask	= ipi_mux_mask,
   	.irq_unmask	= ipi_mux_unmask,
   	.ipi_send_mask	= ipi_mux_send_mask,
   };
   
   void __init sbi_ipi_init(void)
   {
   	//...
   
   	sbi_ipi_virq = irq_create_mapping(domain, RV_IRQ_SOFT);
   	if (!sbi_ipi_virq) {
   		pr_err("unable to create INTC IRQ mapping\n");
   		return;
   	}
   
   	virq = ipi_mux_create(BITS_PER_BYTE, sbi_send_ipi);
   	if (virq <= 0) {
   		pr_err("unable to create muxed IPIs\n");
   		irq_dispose_mapping(sbi_ipi_virq);
   		return;
   	}
   
   	irq_set_chained_handler(sbi_ipi_virq, sbi_ipi_handle);
   }
   
   //arch/riscv/kernel/sbi.c
   static void __sbi_send_ipi_v01(unsigned int cpu)
   {
   	unsigned long hart_mask =
   		__sbi_v01_cpumask_to_hartmask(cpumask_of(cpu));
   	sbi_ecall(SBI_EXT_0_1_SEND_IPI, 0, (unsigned long)(&hart_mask),
   		  0, 0, 0, 0, 0);
   }
   ```

#### b. local_irq/preempt_enable/disable

[PATCH v3 0/5\] kvm: fix latent guest entry/exit bugs - Mark Rutland (kernel.org)](https://lore.kernel.org/all/20220201132926.3301912-1-mark.rutland@arm.com/)

>在 kvm_arch_vcpu_ioctl_run() 中，通过调用 guest_enter_irqoff() 进入一个 RCU 扩展静止状态（EQS），并在调用 guest_exit() 之前取消屏蔽 IRQ，从而退出 EQS。由于在这种情况下 IRQ 进入代码不会唤醒 RCU，我们可能在没有 RCU 监视的情况下运行核心 IRQ 代码和 IRQ 处理程序，导致各种潜在问题。
>
>此外，我们没有通知 lockdep 或跟踪，在客户端执行期间将启用中断，这可能导致跟踪和警告错误地指示中断已被启用的时间过长。
>
>该补丁通过使用新的时序和上下文进入/退出辅助函数来解决这些问题，以确保在客户端虚拟时间中处理中断时带有 RCU 监视，顺序如下：
>
>    guest_timing_enter_irqoff();
>    
>    guest_state_enter_irqoff();
>    <运行 vcpu>
>    guest_state_exit_irqoff();
>    
>    <处理任何未决 IRQ>
>    
>    guest_timing_exit_irqoff();
>
>由于插装可能使用 RCU，我们还必须确保在 EQS 期间不运行任何插装代码。我将关键部分拆分为一个新的 kvm_riscv_enter_exit_vcpu() 辅助函数，并标记为 noinstr。

---

进入或退出访客模式与系统调用非常相似。从宿主内核的角度来看，当进入访客模式时，CPU进入用户空间，退出时返回到内核。

`kvm_guest_enter_irqoff()` 是 `exit_to_user_mode()` 的 KVM 特定变体，而 `kvm_guest_exit_irqoff()` 则是 `enter_from_user_mode()` 的 KVM 变体。这些状态操作具有相同的顺序。

在 `vcpu_run()` 循环的边界处单独处理访客的任务工作，通过 `xfer_to_guest_mode_handle_work()` 完成，这是返回用户空间时处理的工作的一个子集。

不要嵌套 KVM 的进入/退出转换，因为这样做没有意义。

> 中断和常规异常

中断的进入和退出处理，比系统调用和 KVM 转换稍微复杂一些。

如果中断在 CPU 执行用户空间代码时被触发，其进入和退出处理与系统调用完全相同。

如果中断在 CPU 在内核空间执行时被触发，则进入和退出处理稍有不同。仅当中断在 CPU 的空闲任务上下文中被触发时，RCU 状态才会更新。否则，RCU 已经在监视中。Lockdep 和跟踪必须无条件更新。

`irqentry_enter()` 和 `irqentry_exit()` 提供了这一实现。

从架构特定部分看，这与系统调用处理类似：

```c
noinstr void interrupt(struct pt_regs *regs, int nr)
{
  arch_interrupt_enter(regs);
  state = irqentry_enter(regs);

  instrumentation_begin();

  irq_enter_rcu();
  invoke_irq_handler(regs, nr);
  irq_exit_rcu();

  instrumentation_end();

  irqentry_exit(regs, state);
}
```

请注意，实际的中断处理程序的调用是在 `irq_enter_rcu()` 和 `irq_exit_rcu()` 对之间。

`irq_enter_rcu()` 更新抢占计数，使 `in_hardirq()` 返回 true，处理 NOHZ tick 状态和中断时间计算。这意味着，在 `irq_enter_rcu()` 被调用之前，`in_hardirq()` 返回 false。

`irq_exit_rcu()` 处理中断时间计算，撤销抢占计数更新，并最终处理软中断和 NOHZ tick 状态。

理论上，抢占计数可以在 `irqentry_enter()` 中更新。但实际上，将此更新推迟到 `irq_enter_rcu()` 允许抢占计数代码被跟踪，同时也与 `irq_exit_rcu()` 和 `irqentry_exit()` 保持对称，这些在下一段中描述。唯一的缺点是，直到 `irq_enter_rcu()`，早期入口代码必须意识到抢占计数尚未更新为 HARDIRQ_OFFSET 状态。

请注意，`irq_exit_rcu()` 必须在处理软中断之前从抢占计数中移除 HARDIRQ_OFFSET，其处理程序必须在 BH 上下文而不是 irq-disabled 上下文中运行。此外，`irqentry_exit()` 可能会调度，这也要求已经从抢占计数中移除了 HARDIRQ_OFFSET。

尽管中断处理程序预期在本地中断禁用的情况下运行，但从入口/出口的角度来看，中断嵌套是常见的。例如，softirq 处理发生在本地中断启用的 `irqentry_{enter,exit}()` 块中。此外，尽管不常见，但没有什么能阻止中断处理程序重新启用中断。

中断入口/出口代码并不严格需要处理重入性，因为它在本地中断禁用时运行。但是 NMI 可以随时发生，且很多入口代码在两者之间是共享的。

---

我们必须确保在退出客户端计时之前，处理任何未决中断，以便计时器滴答声被视为客户端时间。短暂地解除中断屏蔽，以便处理任何未决中断。没有屏障可确保未决中断被识别，因此我们只能希望 CPU 在启用和禁用之间处理任何未决中断。

```c
int kvm_arch_vcpu_ioctl_run(struct kvm_vcpu *vcpu)
{
    while(ret > 0) {
        /* Check conditions before entering the guest */
		ret = xfer_to_guest_mode_handle_work(vcpu);
		if (ret)
			continue;
		ret = 1;
        
        preempt_disable();
		local_irq_disable();
        
        guest_timing_enter_irqoff();

		kvm_riscv_vcpu_enter_exit(vcpu);
        
        /*
		 * We must ensure that any pending interrupts are taken before
		 * we exit guest timing so that timer ticks are accounted as
		 * guest time. Transiently unmask interrupts so that any
		 * pending interrupts are taken.
		 *
		 * There's no barrier which ensures that pending interrupts are
		 * recognised, so we just hope that the CPU takes any pending
		 * interrupts between the enable and disable.
		 */
		local_irq_enable();
		local_irq_disable();

		guest_timing_exit_irqoff();

		local_irq_enable();
		preempt_enable();
        
       	//...
    }
    //...
}
```

#### c. interrupt flush/update/sync

[RISCV Hypervisor Extension: Interrupts (hybridkernel.com)](https://www.hybridkernel.com/2021/08/08/riscv_hyp_ext_interrupts.html)

```c
int kvm_arch_vcpu_ioctl_run(struct kvm_vcpu *vcpu)
{
    while (ret > 0) {
        /*
		 * We might have got VCPU interrupts updated asynchronously
		 * so update it in HW.
		 */
		kvm_riscv_vcpu_flush_interrupts(vcpu);

		/* Update HVIP CSR for current CPU */
		kvm_riscv_update_hvip(vcpu);
        
        kvm_riscv_vcpu_enter_exit(vcpu);
        
        /* Syncup interrupts state with HW */
		kvm_riscv_vcpu_sync_interrupts(vcpu);
    }
}
```

* `before vcpu run enter: flush/update`

  ```c
  void kvm_riscv_vcpu_flush_interrupts(struct kvm_vcpu *vcpu)
  {
  	struct kvm_vcpu_csr *csr = &vcpu->arch.guest_csr;
  	unsigned long mask, val;
  
  	if (READ_ONCE(vcpu->arch.irqs_pending_mask[0])) {
  		mask = xchg_acquire(&vcpu->arch.irqs_pending_mask[0], 0);
  		val = READ_ONCE(vcpu->arch.irqs_pending[0]) & mask;
  
  		csr->hvip &= ~mask;
  		csr->hvip |= val;
  	}
  
  	/* Flush AIA high interrupts */
  	kvm_riscv_vcpu_aia_flush_interrupts(vcpu);
  }
  
  static void kvm_riscv_update_hvip(struct kvm_vcpu *vcpu)
  {
  	struct kvm_vcpu_csr *csr = &vcpu->arch.guest_csr;
  
  	csr_write(CSR_HVIP, csr->hvip);
  	kvm_riscv_vcpu_aia_update_hvip(vcpu);
  }
  ```



* `after vcpu run exit`

  ```c
  void kvm_riscv_vcpu_sync_interrupts(struct kvm_vcpu *vcpu)
  {
  	unsigned long hvip;
  	struct kvm_vcpu_arch *v = &vcpu->arch;
  	struct kvm_vcpu_csr *csr = &vcpu->arch.guest_csr;
  
  	/* Read current HVIP and VSIE CSRs */
  	csr->vsie = csr_read(CSR_VSIE);
  
  	/* Sync-up HVIP.VSSIP bit changes does by Guest */
  	hvip = csr_read(CSR_HVIP);
  	if ((csr->hvip ^ hvip) & (1UL << IRQ_VS_SOFT)) {
  		if (hvip & (1UL << IRQ_VS_SOFT)) {
  			if (!test_and_set_bit(IRQ_VS_SOFT,
  					      v->irqs_pending_mask))
  				set_bit(IRQ_VS_SOFT, v->irqs_pending);
  		} else {
  			if (!test_and_set_bit(IRQ_VS_SOFT,
  					      v->irqs_pending_mask))
  				clear_bit(IRQ_VS_SOFT, v->irqs_pending);
  		}
  	}
  
  	/* Sync-up AIA high interrupts */
  	kvm_riscv_vcpu_aia_sync_interrupts(vcpu);
  
  	/* Sync-up timer CSRs */
  	kvm_riscv_vcpu_timer_sync(vcpu);
  }
  ```

  





#### d. kvm_riscv_vcpu_enter_exit

`kvm_riscv_vcpu_enter_exit` 实现了guest切入切出，它将调用一段汇编 `__kvm_riscv_switch_to`：

```c
/*
 * Actually run the vCPU, entering an RCU extended quiescent state (EQS) while
 * the vCPU is running.
 *
 * This must be noinstr as instrumentation may make use of RCU, and this is not
 * safe during the EQS.
 */
static void noinstr kvm_riscv_vcpu_enter_exit(struct kvm_vcpu *vcpu)
{
	guest_state_enter_irqoff();
	__kvm_riscv_switch_to(&vcpu->arch);
	vcpu->arch.last_exit_cpu = vcpu->cpu;
	guest_state_exit_irqoff();
}

ENTRY(__kvm_riscv_switch_to)
    /* Save Host GPRs (except A0 and T0-T6) */
    /* Load Guest CSR values */
    la	t4, __kvm_switch_return
    /* Save Host and Restore Guest SSTATUS */
    /* Save Host and Restore Guest SCOUNTEREN */
    /* Save Host STVEC and change it to return path */
    csrrw	t4, CSR_STVEC, t4
    /* Save Host SSCRATCH and change it to struct kvm_vcpu_arch pointer */
    /* Restore Guest SEPC */
    /* Store Host CSR values */
    /* Restore Guest GPRs (except A0) */
    /* Restore Guest A0 */
    //...
    
    /* Resume Guest */
    sret
	
    /* Back to Host */
	.align 2
__kvm_switch_return:    
    /* Swap Guest A0 with SSCRATCH */
	/* Save Guest GPRs (except A0) */
	/* Load Host CSR values */
	/* Save Guest SEPC */
	/* Save Guest A0 and Restore Host SSCRATCH */
	/* Restore Host STVEC */
	/* Save Guest and Restore Host SCOUNTEREN */
	/* Save Guest and Restore Host HSTATUS */
	/* Save Guest and Restore Host SSTATUS */
	/* Store Guest CSR values */
	/* Restore Host GPRs (except A0 and T0-T6) */
	//...	

	/* Return to C code */
	ret
ENDPROC(__kvm_riscv_switch_to)
```

这部分代码注释比较详细，其流程为：

* 首先保存 host 上下文，加载 guest 上下文。其中，host 上下文包括通用、系统寄存器，guest 上下文主要是通用寄存器，之前 `kvm_vcpu_arch_load` 完成了 guest 系统寄存器的恢复（VS 态寄存器）；

* host/guest 上下文切换工作完成后，执行 `sret` 指令进入虚拟机，因为之前 `stvec` 保存了 `__kvm_switch_return` 的地址，虚拟机异常退出后会跳转到 `__kvm_switch_return` 函数；
* `__kvm_switch_return` 函数保存 guest 上下文，恢复 host 上下文；

>`kvm_vcpu_arch_{load,put}` 和 `__kvm_riscv_switch_to/__kvm_switch_return` 两者完成的都是上下文切换工作，为什么代码的位置有所区别？
>
>* `kvm_vcpu_arch_{load,put}` 主要工作是恢复和保存 guest 的 VS 态寄存器值，每个 guest 各一份，当涉及到 **vcpu 线程调度、返回用户态、从 host U 陷入(可能Qemu模拟完陷入或首次进入)** 等场景时，会调用到这两个函数，它们专注于 guest 下所使用的 VS 态寄存器值，和 host 毫无关系；
>* `__kvm_riscv_switch_to/__kvm_switch_return` 两者完成的是 host/guest 上下文切换，即宿主机和虚拟机的执行环境切换，该函数也是所有 guest 和 hypervisor 交互的必经之路，所有的虚拟机陷入模拟操作都需要经历这两个函数，因为必须完成 host/guest 切换，一旦 hypervisor 能够成功处理 guest 退出，直接切入虚拟机就OK了，VS 态寄存器完全不用动；
>
>这样的函数设计，减少了上下文切换的开销（特指 VS 态寄存器）。

# 6 vCPU退出处理

## 6.1 virtual instruction exception

[Illegal instruction exception or virtual instruction exception? · Issue #44 · riscv/riscv-aia (github.com)](https://github.com/riscv/riscv-aia/issues/44)

[RISCV Hypervisor Extension: htinst and virtual instruction exception (hybridkernel.com)](https://www.hybridkernel.com/2021/08/09/riscv_hyp_ext_htinst.html)

[The RISC-V Instruction Set Manual, Volume II: Privileged Architecture | Five EmbedDev (five-embeddev.com)](https://five-embeddev.com/riscv-priv-isa-manual/Priv-v1.12/hypervisor.html)

RISCV HE（监管扩展）引入了一种新的异常类型：虚拟指令异常（代码22）。如果在VS模式或VU模式中，某个指令在HS模式下有效，但在VS模式下由于权限不足或其他原因无效，则不会引发非法指令异常，而是引发虚拟指令异常。以下列表摘自RISCV特权规范，尽管未必涵盖所有情况：

- 在VS模式或VU模式下，如果相应的hcounteren中的位为0而mcounteren中的同一位为1，则尝试访问计数器CSR；
- 在VS模式或VU模式下，尝试执行监管指令（HLV、HLVX、HSV或HFENCE），或访问已实现的监管CSR或VS CSRR，当在HS模式下允许同样的访问（读/写）时；
- 在VU模式下，尝试执行WFI或监管指令（SRET或SFENCE），或访问已实现的监管CSR，当在HS模式下允许同样的访问（读/写）时；
- 在VS模式下，尝试执行WFI，当hstatus.VTW=1且mstatus.TW=0时，除非指令在特定的、有限的时间内完成；
- 在VS模式下，尝试执行SRET，当hstatus.VTSR=1时；
- 在VS模式下，尝试执行SFENCE指令或访问satp，当hstatus.VTVM=1时。 在虚拟指令陷阱中，mtval或stval的写入与非法指令陷阱相同。

htinst提供有关陷入HS模式的指令的信息，如果其值不为0。允许htinst始终为0，不提供关于故障的额外信息。如果值不为0，则有三种可能性：

- 位0为1，并且将位1替换为1可以将该值转换为标准指令的有效编码。这被称为转换指令。
- 位0为1，并且将位1替换为1可以将该值转换为专门为自定义指令设计的指令编码。仅当陷阱指令不是标准指令时，此操作才被允许。
- 当位0和位1都为0时，该值是一种特殊的伪指令。 对于异常类型写入htinst的值相当宽松。例如，对于加载访客页面故障，允许的值包括零、转换的标准指令、自定义值和伪指令。实现总是可以提供0。

目前定义的转换指令包括：

- 对于非压缩的标准加载指令LB、LBU、LH、LHU、LW、LWU、FLW、FLD或FLQ；
- 对于非压缩的标准存储指令SB、SH、SW、SD、FSW、FSD或FSQ；
- 对于标准的原子指令；
- 对于标准的虚拟机加载/存储指令，HLV、HLVX或HSV。 如果陷阱指令是压缩的，则转换的标准指令的位1:0将是二进制01；如果不是压缩的，则为11。对于标准的基本加载和存储指令，仅需检查编码即可。

对于访客页面故障，如果满足以下条件，陷阱指令寄存器将写入一个特殊的伪指令值：(a) 故障由VS阶段地址转换的隐式内存访问引起，且 (b) 向mtval2或htval写入一个非零值（即故障的访客物理地址）。如果这两个条件都满足，则写入mtinst或htinst的值必须取自以下列表；不允许为零。

| 值         | 含义                           |
| ---------- | ------------------------------ |
| 0x00002000 | 32位读取，用于VS阶段的地址转换 |
| 0x00002020 | 32位写入，用于VS阶段的地址转换 |
| 0x00003000 | 64位读取，用于VS阶段的地址转换 |
| 0x00003020 | 64位写入，用于VS阶段的地址转换 |

写入的伪指令用于仅更新VS级别页面表中的A和/或D位。

## 6.2 kvm_riscv_vcpu_exit

```c
/*
 * Return > 0 to return to guest, < 0 on error, 0 (and set exit_reason) on
 * proper exit to userspace.
 */
int kvm_riscv_vcpu_exit(struct kvm_vcpu *vcpu, struct kvm_run *run,
			struct kvm_cpu_trap *trap)
{
	int ret;

	/* If we got host interrupt then do nothing */
	if (trap->scause & CAUSE_IRQ_FLAG)
		return 1;

	/* Handle guest traps */
	ret = -EFAULT;
	run->exit_reason = KVM_EXIT_UNKNOWN;
	switch (trap->scause) {
	case EXC_INST_ILLEGAL:
	case EXC_LOAD_MISALIGNED:
	case EXC_STORE_MISALIGNED:
		if (vcpu->arch.guest_context.hstatus & HSTATUS_SPV) {
			kvm_riscv_vcpu_trap_redirect(vcpu, trap);
			ret = 1;
		}
		break;
	case EXC_VIRTUAL_INST_FAULT:
		if (vcpu->arch.guest_context.hstatus & HSTATUS_SPV)
			ret = kvm_riscv_vcpu_virtual_insn(vcpu, run, trap);
		break;
	case EXC_INST_GUEST_PAGE_FAULT:
	case EXC_LOAD_GUEST_PAGE_FAULT:
	case EXC_STORE_GUEST_PAGE_FAULT:
		if (vcpu->arch.guest_context.hstatus & HSTATUS_SPV)
			ret = gstage_page_fault(vcpu, run, trap);
		break;
	case EXC_SUPERVISOR_SYSCALL:
		if (vcpu->arch.guest_context.hstatus & HSTATUS_SPV)
			ret = kvm_riscv_vcpu_sbi_ecall(vcpu, run);
		break;
	default:
		break;
	}

	/* Print details in-case of error */
	if (ret < 0) {
		kvm_err("VCPU exit error %d\n", ret);
		kvm_err("SEPC=0x%lx SSTATUS=0x%lx HSTATUS=0x%lx\n",
			vcpu->arch.guest_context.sepc,
			vcpu->arch.guest_context.sstatus,
			vcpu->arch.guest_context.hstatus);
		kvm_err("SCAUSE=0x%lx STVAL=0x%lx HTVAL=0x%lx HTINST=0x%lx\n",
			trap->scause, trap->stval, trap->htval, trap->htinst);
	}

	return ret;
}
```

### 1) `kvm_riscv_vcpu_trap_redirect`

[vcpu_exit.c - arch/riscv/kvm/vcpu_exit.c - Linux source code (v6.9-rc6) - Bootlin](https://elixir.bootlin.com/linux/v6.9-rc6/source/arch/riscv/kvm/vcpu_exit.c#L135)

某些来自VU/VS mode的异常，需要kvm在vcpu退出时修改 `vsstatus/sstatus` 的状态，以及 `scause/stval/sepc` 重新赋给 VS 态的寄存器 `vscause/vstval/vsepc`，然后将 `vstvec` 的值赋给 `sepc`，这样在vcpu返回guest时，将重定向到guest os的异常处理程序入口。

```c
/*
	case EXC_INST_ILLEGAL:
	case EXC_LOAD_MISALIGNED:
	case EXC_STORE_MISALIGNED:
*/

/**
 * kvm_riscv_vcpu_trap_redirect -- Redirect trap to Guest
 *
 * @vcpu: The VCPU pointer
 * @trap: Trap details
 */
void kvm_riscv_vcpu_trap_redirect(struct kvm_vcpu *vcpu,
				  struct kvm_cpu_trap *trap)
{
	unsigned long vsstatus = csr_read(CSR_VSSTATUS);

	/* Change Guest SSTATUS.SPP bit */
	vsstatus &= ~SR_SPP;
	if (vcpu->arch.guest_context.sstatus & SR_SPP)
		vsstatus |= SR_SPP;

	/* Change Guest SSTATUS.SPIE bit */
	vsstatus &= ~SR_SPIE;
	if (vsstatus & SR_SIE)
		vsstatus |= SR_SPIE;

	/* Clear Guest SSTATUS.SIE bit */
	vsstatus &= ~SR_SIE;

	/* Update Guest SSTATUS */
	csr_write(CSR_VSSTATUS, vsstatus);

	/* Update Guest SCAUSE, STVAL, and SEPC */
	csr_write(CSR_VSCAUSE, trap->scause);
	csr_write(CSR_VSTVAL, trap->stval);
	csr_write(CSR_VSEPC, trap->sepc);

	/* Set Guest PC to Guest exception vector */
	vcpu->arch.guest_context.sepc = csr_read(CSR_VSTVEC);

	/* Set Guest privilege mode to supervisor */
	vcpu->arch.guest_context.sstatus |= SR_SPP;
}
```

### 2) `kvm_riscv_vcpu_virtual_insn`

[vcpu_insn.c - arch/riscv/kvm/vcpu_insn.c - Linux source code (v6.9-rc6) - Bootlin](https://elixir.bootlin.com/linux/v6.9-rc6/source/arch/riscv/kvm/vcpu_insn.c#L423)

该函数的逻辑大致上是，从 `stval` 读出导致陷入HS mode的异常指令，但从priv spec上看，`stval` 在发生illegal instruction trap 和 virtual instruction trap 时策略上是相同的，但实际写入的值可能会为0或异常指令，这个应该看具体微架构的实现，讨论见：[Ambiguity about *tval in case of virtual instruction exception · Issue #846 · riscv/riscv-isa-manual (github.com)](https://github.com/riscv/riscv-isa-manual/issues/846)。

看目前kvm的实现，处理逻辑上是**有些疑惑的，**具体为：

> `INSN_IS_16BIT(insn)` 在判断是否使能了C扩展，对于 `stval` 没有存储任何信息的情况，kvm将调用 `kvm_riscv_vcpu_unpriv_read` （稍后分析，调用HLV/HSV）获取到异常指令。这段逻辑，我认为应该放在外面的公共路径下，难道不支持C扩展（指令位宽为32bit）的场景下，就能确保 `stval` 的值始终不为零？ C扩展对`stval` 有什么特别的支持吗？在priv spec上，我没找到相关的依据。 

```c
/*
	case EXC_VIRTUAL_INST_FAULT
*/

/**
 * kvm_riscv_vcpu_virtual_insn -- Handle virtual instruction trap
 *
 * @vcpu: The VCPU pointer
 * @run:  The VCPU run struct containing the mmio data
 * @trap: Trap details
 *
 * Returns > 0 to continue run-loop
 * Returns   0 to exit run-loop and handle in user-space.
 * Returns < 0 to report failure and exit run-loop
 */
int kvm_riscv_vcpu_virtual_insn(struct kvm_vcpu *vcpu, struct kvm_run *run,
				struct kvm_cpu_trap *trap)
{
	unsigned long insn = trap->stval;
	struct kvm_cpu_trap utrap = { 0 };
	struct kvm_cpu_context *ct;

	if (unlikely(INSN_IS_16BIT(insn))) {
		if (insn == 0) {
			ct = &vcpu->arch.guest_context;
			insn = kvm_riscv_vcpu_unpriv_read(vcpu, true,
							  ct->sepc,
							  &utrap);
			if (utrap.scause) {
				utrap.sepc = ct->sepc;
				kvm_riscv_vcpu_trap_redirect(vcpu, &utrap);
				return 1;
			}
		}
		if (INSN_IS_16BIT(insn))
			return truly_illegal_insn(vcpu, run, insn);
	}

	switch ((insn & INSN_OPCODE_MASK) >> INSN_OPCODE_SHIFT) {
	case INSN_OPCODE_SYSTEM:
		return system_opcode_insn(vcpu, run, insn);
	default:
		return truly_illegal_insn(vcpu, run, insn);
	}
}

/**
 * kvm_riscv_vcpu_virtual_insn -- Handle virtual instruction trap
 *
 * @vcpu: The VCPU pointer
 * @run:  The VCPU run struct containing the mmio data
 * @trap: Trap details
 *
 * Returns > 0 to continue run-loop
 * Returns   0 to exit run-loop and handle in user-space.
 * Returns < 0 to report failure and exit run-loop
 */
int kvm_riscv_vcpu_virtual_insn(struct kvm_vcpu *vcpu, struct kvm_run *run,
				struct kvm_cpu_trap *trap)
{
	unsigned long insn = trap->stval;
	struct kvm_cpu_trap utrap = { 0 };
	struct kvm_cpu_context *ct;

	if (unlikely(INSN_IS_16BIT(insn))) {
		if (insn == 0) {
			ct = &vcpu->arch.guest_context;
			insn = kvm_riscv_vcpu_unpriv_read(vcpu, true,
							  ct->sepc,
							  &utrap);
			if (utrap.scause) {
				utrap.sepc = ct->sepc;
				kvm_riscv_vcpu_trap_redirect(vcpu, &utrap);
				return 1;
			}
		}
		if (INSN_IS_16BIT(insn))
			return truly_illegal_insn(vcpu, run, insn);
	}

	switch ((insn & INSN_OPCODE_MASK) >> INSN_OPCODE_SHIFT) {
	case INSN_OPCODE_SYSTEM:
		return system_opcode_insn(vcpu, run, insn);
	default:
		return truly_illegal_insn(vcpu, run, insn);
	}
}

static int system_opcode_insn(struct kvm_vcpu *vcpu, struct kvm_run *run,
			      ulong insn)
{
	int i, rc = KVM_INSN_ILLEGAL_TRAP;
	const struct insn_func *ifn;

	for (i = 0; i < ARRAY_SIZE(system_opcode_funcs); i++) {
		ifn = &system_opcode_funcs[i];
		if ((insn & ifn->mask) == ifn->match) {
			rc = ifn->func(vcpu, run, insn);
			break;
		}
	}

	switch (rc) {
	case KVM_INSN_ILLEGAL_TRAP:
		return truly_illegal_insn(vcpu, run, insn);
	case KVM_INSN_VIRTUAL_TRAP:
		return truly_virtual_insn(vcpu, run, insn);
	case KVM_INSN_CONTINUE_NEXT_SEPC:
		vcpu->arch.guest_context.sepc += INSN_LEN(insn);
		break;
	default:
		break;
	}

	return (rc <= 0) ? rc : 1;
}
```

> - [ ] stval/hinst/htval分析
> - [ ] HLV/HSV
> - [ ] insn模拟函数的跳转逻辑分析。
>   - [ ] kvm_riscv_vcpu_unpriv_read

#### `kvm_riscv_vcpu_unpriv_read`

[vcpu_exit.c - arch/riscv/kvm/vcpu_exit.c - Linux source code (v6.9-rc6) - Bootlin](https://elixir.bootlin.com/linux/v6.9-rc6/source/arch/riscv/kvm/vcpu_exit.c#L59)

> **关于HLV/HSV：**
>
> [VS mode access for HLV* and HSV.* in U mode · Issue #72 · riscv/riscv-j-extension (github.com)](https://github.com/riscv/riscv-j-extension/issues/72)
>
> 这些指令提供在U/M/HS下的带两级地址翻译的访存功能，也就是虽然V状态没有使能，用这些指令依然可以得到gva两级翻译后的hpa。

该函数逻辑如下：

```c
/**
 * kvm_riscv_vcpu_unpriv_read -- Read machine word from Guest memory
 *
 * @vcpu: The VCPU pointer
 * @read_insn: Flag representing whether we are reading instruction
 * @guest_addr: Guest address to read
 * @trap: Output pointer to trap details
 */
kvm_riscv_vcpu_unpriv_read
    //swap stvec/hstatus
    +-> old_hstatus = csr_swap(CSR_HSTATUS, 
                               vcpu->arch.guest_context.hstatus);
		old_stvec = csr_swap(CSR_STVEC,
                              (ulong)&__kvm_riscv_unpriv_trap);
	//read insn: HLV
	+-> /*
		 * HLVX.HU instruction
		 * 0110010 00011 rs1 100 rd 1110011
		 */
    //write back to stvec/hstatus
    +-> csr_write(CSR_STVEC, old_stvec);
		csr_write(CSR_HSTATUS, old_hstatus);

SYM_CODE_START(__kvm_riscv_unpriv_trap)
	/*
	 * We assume that faulting unpriv load/store instruction is
	 * 4-byte long and blindly increment SEPC by 4.
	 *
	 * The trap details will be saved at address pointed by 'A0'
	 * register and we use 'A1' register as temporary.
	 */
	csrr	a1, CSR_SEPC
	REG_S	a1, (KVM_ARCH_TRAP_SEPC)(a0)
	addi	a1, a1, 4
	csrw	CSR_SEPC, a1
	csrr	a1, CSR_SCAUSE
	REG_S	a1, (KVM_ARCH_TRAP_SCAUSE)(a0)
	csrr	a1, CSR_STVAL
	REG_S	a1, (KVM_ARCH_TRAP_STVAL)(a0)
	csrr	a1, CSR_HTVAL
	REG_S	a1, (KVM_ARCH_TRAP_HTVAL)(a0)
	csrr	a1, CSR_HTINST
	REG_S	a1, (KVM_ARCH_TRAP_HTINST)(a0)
	sret
SYM_CODE_END(__kvm_riscv_unpriv_trap)
```

**这段逻辑也不清晰，**HLV/HSV指令在HS mode下理论上是可以正常运行的，因为hypervisor完全没有必要配置这个HLV异常，而且从对应的异常处理程序 `__kvm_riscv_unpriv_trap` 来看，该函数只是简单的配置了下 `trap`，目的应该是将该异常路由到VS mode去处理，我猜测这是为支持嵌套虚拟化所做的处理。

#### `system_opcode_insn`

[vcpu_insn.c - arch/riscv/kvm/vcpu_insn.c - Linux source code (v6.9-rc6) - Bootlin](https://elixir.bootlin.com/linux/v6.9-rc6/source/arch/riscv/kvm/vcpu_insn.c#L383)

```c
static const struct insn_func system_opcode_funcs[] = {
	{
		.mask  = INSN_MASK_CSRRW,
		.match = INSN_MATCH_CSRRW,
		.func  = csr_insn,
	},
	{
		.mask  = INSN_MASK_CSRRS,
		.match = INSN_MATCH_CSRRS,
		.func  = csr_insn,
	},
	{
		.mask  = INSN_MASK_CSRRC,
		.match = INSN_MATCH_CSRRC,
		.func  = csr_insn,
	},
	{
		.mask  = INSN_MASK_CSRRWI,
		.match = INSN_MATCH_CSRRWI,
		.func  = csr_insn,
	},
	{
		.mask  = INSN_MASK_CSRRSI,
		.match = INSN_MATCH_CSRRSI,
		.func  = csr_insn,
	},
	{
		.mask  = INSN_MASK_CSRRCI,
		.match = INSN_MATCH_CSRRCI,
		.func  = csr_insn,
	},
	{
		.mask  = INSN_MASK_WFI,
		.match = INSN_MATCH_WFI,
		.func  = wfi_insn,
	},
};

static int system_opcode_insn(struct kvm_vcpu *vcpu, struct kvm_run *run,
			      ulong insn)
{
	int i, rc = KVM_INSN_ILLEGAL_TRAP;
	const struct insn_func *ifn;

	for (i = 0; i < ARRAY_SIZE(system_opcode_funcs); i++) {
		ifn = &system_opcode_funcs[i];
		if ((insn & ifn->mask) == ifn->match) {
			rc = ifn->func(vcpu, run, insn);
			break;
		}
	}

	switch (rc) {
	case KVM_INSN_ILLEGAL_TRAP:
		return truly_illegal_insn(vcpu, run, insn);
	case KVM_INSN_VIRTUAL_TRAP:
		return truly_virtual_insn(vcpu, run, insn);
	case KVM_INSN_CONTINUE_NEXT_SEPC:
		vcpu->arch.guest_context.sepc += INSN_LEN(insn);
		break;
	default:
		break;
	}

	return (rc <= 0) ? rc : 1;
}
```

* `csr_insn`

  [vcpu_insn.c - arch/riscv/kvm/vcpu_insn.c - Linux source code (v6.9-rc6) - Bootlin](https://elixir.bootlin.com/linux/v6.9-rc6/source/arch/riscv/kvm/vcpu_insn.c#L263)

  - [x] 系统指令模拟

  对于VS mode下访问CSR的指令模拟，首先在内核中模拟，目前kvm-riscv提供的支持较少，包括：`aia/pmu/zkr`，如果kvm无法模拟或失败，则rc赋为KVM_INSN_EXIT_TO_USER_SPACE，退出到用户态模拟：

  ```c
  static const struct csr_func csr_funcs[] = {
  	KVM_RISCV_VCPU_AIA_CSR_FUNCS
  	KVM_RISCV_VCPU_HPMCOUNTER_CSR_FUNCS
  	{ .base = CSR_SEED, .count = 1, .func = seed_csr_rmw },
  };
  
  static int seed_csr_rmw(struct kvm_vcpu *vcpu, unsigned int csr_num,
  			unsigned long *val, unsigned long new_val,
  			unsigned long wr_mask)
  {
  	if (!riscv_isa_extension_available(vcpu->arch.isa, ZKR))
  		return KVM_INSN_ILLEGAL_TRAP;
  
  	return KVM_INSN_EXIT_TO_USER_SPACE;
  }
  ```

* `wfi_insn`

  kvm对wfi指令的模拟，将vcpu置于TASK_INTERRUPTIBLE态。处于这个状态的进程因为等待某某事件的发生（比如等待socket连接、等待信号量），而被挂起。这些进程的task_struct结构（进程控制块）被放入对应事件的等待队列中。当这些事件发生时（由外部中断触发、或由其他进程触发），对应的等待队列中的一个或多个进程将被唤醒。
  
  > 通过ps命令会看到，一般情况下，进程列表中的绝大多数进程都处于TASK_INTERRUPTIBLE状态（除非机器的负载很高）。毕竟CPU就这么几个，进程动辄几十上百个，如果不是绝大多数进程都在睡眠，CPU又怎么响应得过来。
  
  ```c
  static int wfi_insn(struct kvm_vcpu *vcpu, struct kvm_run *run, ulong insn)
  {
  	vcpu->stat.wfi_exit_stat++;
  	kvm_riscv_vcpu_wfi(vcpu);
  	return KVM_INSN_CONTINUE_NEXT_SEPC;
  }
  
  /**
   * kvm_riscv_vcpu_wfi -- Emulate wait for interrupt (WFI) behaviour
   *
   * @vcpu: The VCPU pointer
   */
  void kvm_riscv_vcpu_wfi(struct kvm_vcpu *vcpu)
  {
  	if (!kvm_arch_vcpu_runnable(vcpu)) {
  		kvm_vcpu_srcu_read_unlock(vcpu);
  		kvm_vcpu_halt(vcpu);
  		kvm_vcpu_srcu_read_lock(vcpu);
  	}
  }
  
  kvm_vcpu_halt
      +-> kvm_vcpu_block
      	+-> kvm_arch_vcpu_blocking
      		+-> kvm_arch_vcpu_blocking(vcpu);
  				for (;;) {
                      set_current_state(TASK_INTERRUPTIBLE);
  
                      if (kvm_vcpu_check_block(vcpu) < 0)
                          break;
  
                      waited = true;
                      schedule();
                  }
  				kvm_arch_vcpu_unblocking(vcpu);
  
  -----------------------------------------------------------------
  void kvm_arch_vcpu_blocking(struct kvm_vcpu *vcpu)
  {
  	kvm_riscv_aia_wakeon_hgei(vcpu, true);
  }
  
  void kvm_arch_vcpu_unblocking(struct kvm_vcpu *vcpu)
  {
  	kvm_riscv_aia_wakeon_hgei(vcpu, false);
  }
  
  void kvm_riscv_aia_wakeon_hgei(struct kvm_vcpu *owner, bool enable)
  {
  	int hgei;
  
  	if (!kvm_riscv_aia_available())
  		return;
  
  	hgei = aia_find_hgei(owner);
  	if (hgei > 0) {
  		if (enable)
  			csr_set(CSR_HGEIE, BIT(hgei));
  		else
  			csr_clear(CSR_HGEIE, BIT(hgei));
  	}
  }
  ```
  

#### `truly_illegal/virtual_insn`

```c
static int truly_illegal_insn(struct kvm_vcpu *vcpu, struct kvm_run *run,
			      ulong insn)
{
	struct kvm_cpu_trap utrap = { 0 };

	/* Redirect trap to Guest VCPU */
	utrap.sepc = vcpu->arch.guest_context.sepc;
	utrap.scause = EXC_INST_ILLEGAL;
	utrap.stval = insn;
	utrap.htval = 0;
	utrap.htinst = 0;
	kvm_riscv_vcpu_trap_redirect(vcpu, &utrap);

	return 1;
}

static int truly_virtual_insn(struct kvm_vcpu *vcpu, struct kvm_run *run,
			      ulong insn)
{
	struct kvm_cpu_trap utrap = { 0 };

	/* Redirect trap to Guest VCPU */
	utrap.sepc = vcpu->arch.guest_context.sepc;
	utrap.scause = EXC_VIRTUAL_INST_FAULT;
	utrap.stval = insn;
	utrap.htval = 0;
	utrap.htinst = 0;
	kvm_riscv_vcpu_trap_redirect(vcpu, &utrap);

	return 1;
}
```

### 3) `kvm_riscv_vcpu_sbi_ecall`

[vcpu_sbi.c - arch/riscv/kvm/vcpu_sbi.c - Linux source code (v6.9-rc6) - Bootlin](https://elixir.bootlin.com/linux/v6.9-rc6/source/arch/riscv/kvm/vcpu_sbi.c#L416)

```c
int kvm_riscv_vcpu_sbi_ecall(struct kvm_vcpu *vcpu, struct kvm_run *run)
{
	int ret = 1;
	bool next_sepc = true;
	struct kvm_cpu_context *cp = &vcpu->arch.guest_context;
	const struct kvm_vcpu_sbi_extension *sbi_ext;
	struct kvm_cpu_trap utrap = {0};
	struct kvm_vcpu_sbi_return sbi_ret = {
		.out_val = 0,
		.err_val = 0,
		.utrap = &utrap,
	};
	bool ext_is_v01 = false;
    
    //从一个全局数组里找到sbi_id对应的kvm_sbi_entry
	sbi_ext = kvm_vcpu_sbi_find_ext(vcpu, cp->a7);
	if (sbi_ext && sbi_ext->handler) {
#ifdef CONFIG_RISCV_SBI_V01
        //旧版SBI-v0.1支持的EIDs在#0x00~#0x08
		if (cp->a7 >= SBI_EXT_0_1_SET_TIMER &&
		    cp->a7 <= SBI_EXT_0_1_SHUTDOWN)
			ext_is_v01 = true;
#endif
        //根据sbi_id调用具体的vcpu_sbi_ext_* handler
		ret = sbi_ext->handler(vcpu, run, &sbi_ret);
	} else {
		/* Return error for unsupported SBI calls */
		cp->a0 = SBI_ERR_NOT_SUPPORTED;
		goto ecall_done;
	}

	/*
	 * When the SBI extension returns a Linux error code, it exits the ioctl
	 * loop and forwards the error to userspace.
	 */
    //ret<0需退出到用户态模拟SBI
	if (ret < 0) {
		next_sepc = false;
		goto ecall_done;
	}

	/* Handle special error cases i.e trap, exit or userspace forward */
    //kvm模拟sbi完成，将结果转发到guest os
	if (sbi_ret.utrap->scause) {
		/* No need to increment sepc or exit ioctl loop */
		ret = 1;
		sbi_ret.utrap->sepc = cp->sepc;
		kvm_riscv_vcpu_trap_redirect(vcpu, sbi_ret.utrap);
		next_sepc = false;
		goto ecall_done;
	}

	/* Exit ioctl loop or Propagate the error code the guest */
	if (sbi_ret.uexit) {
		next_sepc = false;
		ret = 0;
	} else {
		cp->a0 = sbi_ret.err_val;
		ret = 1;
	}
ecall_done:
	if (next_sepc)
		cp->sepc += 4;
	/* a1 should only be updated when we continue the ioctl loop */
	if (!ext_is_v01 && ret == 1)
		cp->a1 = sbi_ret.out_val;

	return ret;
}
```

该函数在整体框架上，支持了 `sbi_ret/ret` 的协同处理，`ret` 是Linux error code用于指示是否进入/退出ioctl run loop，`sbi_ret` 涉及的内容 (utrap/out_val) 用于指示guest os发起的SBI调用的返回结果。核心在于 `ret = sbi_ext->handler(vcpu, run, &sbi_ret)`，展开代码：

```c
struct kvm_vcpu_sbi_return {
	unsigned long out_val;
	unsigned long err_val;
	struct kvm_cpu_trap *utrap;
	bool uexit;
}

struct kvm_vcpu_sbi_extension {
	unsigned long extid_start;
	unsigned long extid_end;

	bool default_disabled;

	/**
	 * SBI extension handler. It can be defined for a given extension or group of
	 * extension. But it should always return linux error codes rather than SBI
	 * specific error codes.
	 */
	int (*handler)(struct kvm_vcpu *vcpu, struct kvm_run *run,
		       struct kvm_vcpu_sbi_return *retdata);

	/* Extension specific probe function */
	unsigned long (*probe)(struct kvm_vcpu *vcpu);
};

/*
 * SBI extension IDs specific to KVM. This is not the same as the SBI
 * extension IDs defined by the RISC-V SBI specification.
 */
enum KVM_RISCV_SBI_EXT_ID {
	KVM_RISCV_SBI_EXT_V01 = 0,
	KVM_RISCV_SBI_EXT_TIME,
	KVM_RISCV_SBI_EXT_IPI,
	KVM_RISCV_SBI_EXT_RFENCE,
	KVM_RISCV_SBI_EXT_SRST,
	KVM_RISCV_SBI_EXT_HSM,
	KVM_RISCV_SBI_EXT_PMU,
	KVM_RISCV_SBI_EXT_EXPERIMENTAL,
	KVM_RISCV_SBI_EXT_VENDOR,
	KVM_RISCV_SBI_EXT_DBCN,
	KVM_RISCV_SBI_EXT_STA,
	KVM_RISCV_SBI_EXT_MAX,
};

struct kvm_riscv_sbi_extension_entry {
	enum KVM_RISCV_SBI_EXT_ID ext_idx;
	const struct kvm_vcpu_sbi_extension *ext_ptr;
};

static const struct kvm_riscv_sbi_extension_entry sbi_ext[] = {
	{
		.ext_idx = KVM_RISCV_SBI_EXT_V01,
		.ext_ptr = &vcpu_sbi_ext_v01,
	},
	{
		.ext_idx = KVM_RISCV_SBI_EXT_MAX, /* Can't be disabled */
		.ext_ptr = &vcpu_sbi_ext_base,
	},
	{
		.ext_idx = KVM_RISCV_SBI_EXT_TIME,
		.ext_ptr = &vcpu_sbi_ext_time,
	},
	//...
};

const struct kvm_vcpu_sbi_extension *kvm_vcpu_sbi_find_ext(
				struct kvm_vcpu *vcpu, unsigned long extid)
{
	struct kvm_vcpu_sbi_context *scontext = &vcpu->arch.sbi_context;
	const struct kvm_riscv_sbi_extension_entry *entry;
	const struct kvm_vcpu_sbi_extension *ext;
	int i;

	for (i = 0; i < ARRAY_SIZE(sbi_ext); i++) {
		entry = &sbi_ext[i];
		ext = entry->ext_ptr;

		if (ext->extid_start <= extid && ext->extid_end >= extid) {
			if (entry->ext_idx >= KVM_RISCV_SBI_EXT_MAX ||
			    scontext->ext_status[entry->ext_idx] ==
						KVM_RISCV_SBI_EXT_STATUS_ENABLED)
				return ext;

			return NULL;
		}
	}

	return NULL;
}
```

#### KVM_RISCV_SBI_EXT_V01: `vcpu_sbi_ext_v0`

[vcpu_sbi_v01.c - arch/riscv/kvm/vcpu_sbi_v01.c - Linux source code (v6.9-rc6) - Bootlin](https://elixir.bootlin.com/linux/v6.9-rc6/source/arch/riscv/kvm/vcpu_sbi_v01.c#L110)



#### KVM_RISCV_SBI_EXT_MAX: `vcpu_sbi_ext_base`

[vcpu_sbi_base.c - arch/riscv/kvm/vcpu_sbi_base.c - Linux source code (v6.9-rc6) - Bootlin](https://elixir.bootlin.com/linux/v6.9-rc6/source/arch/riscv/kvm/vcpu_sbi_base.c#L69)

`EID #0x10` 表示基本扩展。基本扩展旨在尽可能简洁。因此，它仅包含用于探测可用的SBI扩展以及查询SBI版本的功能。基本扩展中的所有函数必须由所有SBI实现支持，因此没有定义错误返回值。

| 函数名                   | SBI 版本 | FID  | EID  |
| ------------------------ | -------- | ---- | ---- |
| sbi_get_sbi_spec_version | 0.2      | 0    | 0x10 |
| sbi_get_sbi_impl_id      | 0.2      | 1    | 0x10 |
| sbi_get_sbi_impl_version | 0.2      | 2    | 0x10 |
| sbi_probe_extension      | 0.2      | 3    | 0x10 |
| sbi_get_mvendorid        | 0.2      | 4    | 0x10 |
| sbi_get_marchid          | 0.2      | 5    | 0x10 |
| sbi_get_mimpid           | 0.2      | 6    | 0x10 |

```c
enum sbi_ext_id {
#ifdef CONFIG_RISCV_SBI_V01
	SBI_EXT_0_1_SET_TIMER = 0x0,
	SBI_EXT_0_1_CONSOLE_PUTCHAR = 0x1,
	SBI_EXT_0_1_CONSOLE_GETCHAR = 0x2,
	SBI_EXT_0_1_CLEAR_IPI = 0x3,
	SBI_EXT_0_1_SEND_IPI = 0x4,
	SBI_EXT_0_1_REMOTE_FENCE_I = 0x5,
	SBI_EXT_0_1_REMOTE_SFENCE_VMA = 0x6,
	SBI_EXT_0_1_REMOTE_SFENCE_VMA_ASID = 0x7,
	SBI_EXT_0_1_SHUTDOWN = 0x8,
#endif
	SBI_EXT_BASE = 0x10,
	SBI_EXT_TIME = 0x54494D45,
	SBI_EXT_IPI = 0x735049,
	//...
};
```



#### KVM_RISCV_SBI_EXT_TIME: `vcpu_sbi_ext_time`

[vcpu_sbi_replace.c - arch/riscv/kvm/vcpu_sbi_replace.c - Linux source code (v6.9-rc6) - Bootlin](https://elixir.bootlin.com/linux/v6.9-rc6/source/arch/riscv/kvm/vcpu_sbi_replace.c#L39)

`EID #0x54494D45 "TIME"` 替代了传统的计时器扩展。它遵循在v0.2中定义的新的调用约定。

```c
// FID #0
struct sbiret sbi_set_timer(uint64_t stime_value);
```

在 `stime_value` 时间之后，为下一个事件设置时钟。`stime_value` 以绝对时间表示。此函数还必须清除挂起的计时器中断位。如果监管者希望在不安排下一个计时器事件的情况下，清除计时器中断，可以请求一个无限远的计时器中断（即(uint64_t)-1），或者通过清除 `sie.STIE` 寄存器位来屏蔽计时器中断。

| 函数名        | SBI 版本 | FID  | EID        |
| ------------- | -------- | ---- | ---------- |
| sbi_set_timer | 0.2      | 0    | 0x54494D45 |

---

```c
static int kvm_sbi_ext_time_handler(struct kvm_vcpu *vcpu, struct kvm_run *run,
				    struct kvm_vcpu_sbi_return *retdata)
{
	struct kvm_cpu_context *cp = &vcpu->arch.guest_context;
	u64 next_cycle;

	if (cp->a6 != SBI_EXT_TIME_SET_TIMER) {
		retdata->err_val = SBI_ERR_INVALID_PARAM;
		return 0;
	}

	kvm_riscv_vcpu_pmu_incr_fw(vcpu, SBI_PMU_FW_SET_TIMER);
#if __riscv_xlen == 32
	next_cycle = ((u64)cp->a1 << 32) | (u64)cp->a0;
#else
	next_cycle = (u64)cp->a0;
#endif
	kvm_riscv_vcpu_timer_next_event(vcpu, next_cycle);

	return 0;
}
```

### 4) `gstage_page_fault`

[vcpu_exit.c - arch/riscv/kvm/vcpu_exit.c - Linux source code (v6.9-rc6) - Bootlin](https://elixir.bootlin.com/linux/v6.9-rc6/source/arch/riscv/kvm/vcpu_exit.c#L13)

- [x] 具体分析见 `ch5_内存虚拟化` 





# 7 vCPU调度

## 7.1 基本流程

本节主要关注的是：VCPU是如何与宿主机的调度融合在一起的。现代处理器通常都是多对称处理，操作系统一般可以自由地将VCPU，调度到任何一个物理CPU上运行。当VCPU被频繁的调度时，可能会影响到虚拟机的性能，因为这涉及到VCPU上下文被换入换出的巨大开销。

下图展示了典型的虚拟机和普通进程运行的情况。虚拟机的每一个VCPU都对应宿主机中的一个线程，通过宿主机内核调度器进行统一调度管理。如果不将虚拟机的VCPU线程绑定到物理CPU上（VCPU绑核），那么VCPU线程可能在每次运行时，被调度到不同的物理CPU上，KVM必须能够处理这种情况。

<img src="https://cdn.jsdelivr.net/gh/MaskerDad/BlogImage@main/image-20240506193400276.png" alt="image-20240506193400276" style="zoom:50%;" />

站在host的角度看，vcpu只是其创建的一个普通线程，因此它也需要被host os的调度器管理。当为vcpu线程分配的时间片用完以后，其需要让出物理cpu。在其再一次被调度时，其又需要切入guest运行。因此，在vcpu相关的线程切换时，会同时涉及以下两部分上下文：

* `vcpu` 所在的普通线程上下文
* `vcpu` guest和host之间切换的上下文

那么如何在切换vcpu线程时，触发guest和host的切入切出操作呢？让我们想一下内核的一贯做法，如内核在执行某操作时需要其它模块配合，它就可以提供一个 `notifier` 。需要配合的模块，将自己的回调函数注册到该`notifier` 中，当该操作实际执行时，可以遍历并执行 `notifier` 中已注册的函数。从而使对该操作感兴趣的模块，在其回调函数中定制自身的逻辑。

为了使被调度线程在调度时，能执行其特定的函数，调度器也为每个线程提供了一个 `preempt_notifiers`。因此vcpu可以向 `preempt_notifiers` 注册一个通知，在线程被sched out或sched in时，调度器将调用其所注册的通知处理函数，而vcpu只需要在通知处理函数中，实现vcpu的guest/host切入切出操作即可。以下为其流程图：

![img](https://pic1.zhimg.com/v2-ebebe7c47fbb7a7f15f359b6b1d74a4c_b.jpg)

1. vcpu运行前向preempt_notifiers通知链注册一个通知，该通知包含其对应线程被seched in和sched out时需要执行的回调函数；
2. 当vcpu正在运行guest程序时。host触发timer中断，并在中断处理流程中检测到vcpu线程的时间片已用完，因此触发线程调度流程；
3. 调度器调用preempt_notifiers通知链中，所有已注册通知的sched_out回调函数；
4. 回调函数执行vcpu切出操作，在该操作中先保存guest上下文，然后恢复vcpu对应线程的host上下文；
5. vcpu切出完成后，就可以执行host的线程切换流程了。此时需要保存host线程的上下文，然后恢复下一个需要运行线程的上下文；
6. 当该线程再次被调度后，则会执行上图右边的操作。其流程为线程切出时的逆操作

## 7.2 vcpu_load/vcpu_put

与VCPU调度密切相关的两个函数是：`vcpu_load` 和 `vcpu_put`。`vcpu_load` 负责将VCPU状态加载到物理CPU上，`vcpu_put` 负责将当前物理CPU上运行的VCPU调度出去时，把VCPU状态保存起来。

`vcpu_load` 代码如下：

```c
/*
 * Switches to specified vcpu, until a matching vcpu_put()
 */
void vcpu_load(struct kvm_vcpu *vcpu)
{
	int cpu = get_cpu();

	__this_cpu_write(kvm_running_vcpu, vcpu);
	preempt_notifier_register(&vcpu->preempt_notifier);
	kvm_arch_vcpu_load(vcpu, cpu);
	put_cpu();
}
EXPORT_SYMBOL_GPL(vcpu_load);

kvm_init
    +-> kvm_preempt_ops.sched_in = kvm_sched_in;
		kvm_preempt_ops.sched_out = kvm_sched_out;

kvm_vcpu_init
    +-> preempt_notifier_init(&vcpu->preempt_notifier, &kvm_preempt_ops);

static void kvm_sched_in(struct preempt_notifier *pn, int cpu)
{
	struct kvm_vcpu *vcpu = preempt_notifier_to_vcpu(pn);

	WRITE_ONCE(vcpu->preempted, false);
	WRITE_ONCE(vcpu->ready, false);

	__this_cpu_write(kvm_running_vcpu, vcpu);
	kvm_arch_sched_in(vcpu, cpu);
	kvm_arch_vcpu_load(vcpu, cpu);
}

static void kvm_sched_out(struct preempt_notifier *pn,
			  struct task_struct *next)
{
	struct kvm_vcpu *vcpu = preempt_notifier_to_vcpu(pn);

	if (current->on_rq) {
		WRITE_ONCE(vcpu->preempted, true);
		WRITE_ONCE(vcpu->ready, true);
	}
	kvm_arch_vcpu_put(vcpu);
	__this_cpu_write(kvm_running_vcpu, NULL);
}
```

get_cpu禁止抢占并返回当前cpu_id，put_cpu开启抢占。在这中间的两个函数，preempt_notifier_register注册一个抢占回调`vcpu->preempt_notifier`，这个通知对象的回调函数在创建VCPU的时候，被初始化为`kvm_preempt_ops`，而 `kvm_preempt_ops` 的sched_in和sched_out回调，则在KVM模块初始化时被赋值。

当VCPU线程被抢占时会调用 `kvm_sched_out`，当VCPU线程抢占了别的线程时会调用 `kvm_sched_in`。注意，只有在当前的VCPU线程处于跟VCPU相关的ioctl中时，才会注册该通知回调。因为VCPU如果并没有执行任何动作，就不需要绑定到真实的物理CPU上去。

与 `vcpu_load` 对应的是 `vcpu_put`，代码如下：

```c
void vcpu_put(struct kvm_vcpu *vcpu)
{
	preempt_disable();
	kvm_arch_vcpu_put(vcpu);
	preempt_notifier_unregister(&vcpu->preempt_notifier);
	__this_cpu_write(kvm_running_vcpu, NULL);
	preempt_enable();
}
EXPORT_SYMBOL_GPL(vcpu_put)
```

可见，`vcpu_put` 和 `vcpu_load` 是两个相反的过程，它们一般在ioctl(KVM_RUN)的开始和返回时调用，是KVM通用层的函数，与之对应的是架构相关的两个函数 `kvm_arch_vcpu_load` 和 `kvm_arch_vcpu_put`。

KVM完全融进了Linux中，物理CPU不仅会在VCPU做调度，而且会在VCPU和普通线程之间做调度。下图展示了在两个物理CPU上，一个普通进程1和一个VCPU1的调度情况。

<img src="https://cdn.jsdelivr.net/gh/MaskerDad/BlogImage@main/image-20240506193808362.png" alt="image-20240506193808362" style="zoom:50%;" />

PCPU1和PCPU2表示两个物理CPU实体，普通进程1和VCPU1表示保存的进程和VCPU线程对应的线程信息。上图中的流程，如下：

1. Step-1：内核调用 `vcpu_load` 将VCPU1与PCPU1关联起来，如果是第一次调用ioctl(KVM_RUN)，则 `vcpu_load` 在`kvm_vcpu_ioctl`函数的开始被调用。如果是被调度进来的，则是在`kvm_sched_in`中调用kvm_arch_vcpu_load函数，完成关联过程。
2. Step-2：当PCPU1执行虚拟机代码时，当前线程是禁止抢占以及被中断打断的，但是中断却可以触发VM Exit，也就是让虚拟机退出到宿主机，退出并处理一些必要的工作之后就会开启中断和抢占，这样PCPU1就有可能去调度别的线程或VCPU。
3. Step-3：VCPU1的线程被抢占之后，调用 `kvm_sched_out`。当又该调度VCPU1时，系统却把它调度到物理CPU2上，那么就需要将VCPU1的状态与PCPU2关联起来，所以这个时候需要再调用 `kvm_sched_in` 来完成这个关联。

下图展示了，在一个VCPU相关的ioctl调用过程中，VCPU与物理CPU关联和解除关联的相关函数调用。

<img src="https://cdn.jsdelivr.net/gh/MaskerDad/BlogImage@main/image-20240506193850699.png" alt="image-20240506193850699" style="zoom:50%;" />

---

`vcpu_load` 会调用 `kvm_arch_vcpu_load`，将当前物理CPU与用户态指定的VCPU绑定起来，`vcpu_load` 还会注册一个抢占通知回调。当VCPU所在线程被抢占时，会调用之前注册的被抢占回调函数 `kvm_sched_out`，该函数调用 `kvm_arch_vcpu_put`，将VCPU与物理CPU解除关联。

当VCPU所在线程又被重新调度时，会调用 `kvm_sched_in`，该函数调用 `kvm_arch_vcpu_load`，重新将VCPU与物理CPU关联起来。VCPU通过 `kvm_sched_out` 和 `kvm_sched_in` 两个函数，与物理CPU进行关联与解除关联。最后ioctl返回时调用 `vcpu_put`，`vcpu_put` 除了解除关联外，还会取消在 `vcpu_load` 中注册的抢占通知回调。

对于 `kvm_arch_vcpu_load/put`，代码如下：

```c
void kvm_arch_vcpu_load(struct kvm_vcpu *vcpu, int cpu)
{
	struct kvm_vcpu_csr *csr = &vcpu->arch.guest_csr;
	struct kvm_vcpu_config *cfg = &vcpu->arch.cfg;

	csr_write(CSR_VSSTATUS, csr->vsstatus);
	csr_write(CSR_VSIE, csr->vsie);
	csr_write(CSR_VSTVEC, csr->vstvec);
	csr_write(CSR_VSSCRATCH, csr->vsscratch);
	csr_write(CSR_VSEPC, csr->vsepc);
	csr_write(CSR_VSCAUSE, csr->vscause);
	csr_write(CSR_VSTVAL, csr->vstval);
	csr_write(CSR_HVIP, csr->hvip);
	csr_write(CSR_VSATP, csr->vsatp);
	csr_write(CSR_HENVCFG, cfg->henvcfg);
    
	if (IS_ENABLED(CONFIG_32BIT))
		csr_write(CSR_HENVCFGH, cfg->henvcfg >> 32);
	if (riscv_has_extension_unlikely(RISCV_ISA_EXT_SMSTATEEN)) {
		csr_write(CSR_HSTATEEN0, cfg->hstateen0);
		if (IS_ENABLED(CONFIG_32BIT))
			csr_write(CSR_HSTATEEN0H, cfg->hstateen0 >> 32);
	}

	kvm_riscv_vcpu_timer_restore(vcpu);
    
    // aia/fp/vector...

	vcpu->cpu = cpu;
}

void kvm_arch_vcpu_put(struct kvm_vcpu *vcpu)
{
	struct kvm_vcpu_csr *csr = &vcpu->arch.guest_csr;

	vcpu->cpu = -1;

	kvm_riscv_vcpu_timer_save(vcpu);

    // aia/fp/vector...
    
	csr->vsstatus = csr_read(CSR_VSSTATUS);
	csr->vsie = csr_read(CSR_VSIE);
	csr->vstvec = csr_read(CSR_VSTVEC);
	csr->vsscratch = csr_read(CSR_VSSCRATCH);
	csr->vsepc = csr_read(CSR_VSEPC);
	csr->vscause = csr_read(CSR_VSCAUSE);
	csr->vstval = csr_read(CSR_VSTVAL);
	csr->hvip = csr_read(CSR_HVIP);
	csr->vsatp = csr_read(CSR_VSATP);
}
```

整体上看，不同于vcpu world switch(guest/host)，`kvm_arch_vcpu_load/put` 将加载或保存VS mode的CSR，有三种场景需要调用这套接口 (load和put是对称的关系，也就是说load后，对称的调用路径上一定要用put) ：

* vcpu首次拉起，进入ioctl run loop，当然需要load一次；

* 退出ioctl run loop，到用户态进行模拟工作(user csr/sbi/mmio)，需要put一次；

  > 思考一下，为什么退出到用户态需要put？其实不put也不会出现上下文丢失的情况，但前提是不能注销对应的notifier，这样在host user触发的调度流程中，每次都需要调用 `kvm_arch_vcpu_load/put` 进行vcpu CSR的ctx_switch，这相比于直接在内核态put并注销notifier，开销显然更大 (在退出kvm前put一次就可以)。

* vcpu处于guest run(VS/VU mode)状态，vcpu陷出并参与全局调度，此时 `kvm_sched_out/int` 还未注销，因此会首先put保存vcpu CSR状态，再进行host vcpu调度(这涉及到vcpu host_ctx switch)；

   

# 8 kvm demo













