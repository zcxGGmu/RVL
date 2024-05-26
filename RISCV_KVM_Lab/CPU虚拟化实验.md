# -1 问题

* `1.3-1)`：`hardware_enable_all` 注释需要更新，`kvm_reboot` 函数已经删除；
* 

```c
zhouquan@nj.iscas.ac.cn
kvm-riscv@lists.infradead.org
    subscribe

中科院账号密码：
zhouquan@nj.iscas.ac.cn
Zq@666glorymnu
```



---

![Diagram showing how the PBMT bits in Sv39, Sv48, and Sv57 virtual memory addressing modes can be used to override the specified Physical Memory Attributes (PMAs).](https://pbs.twimg.com/media/FH3V-a0XoAE_I-_?format=jpg&name=4096x4096)



# 0 规划

- [x] CPU虚拟化分析/基于riscv架构（qemu-8.1/linux-6.8）
  - [x] 自顶向下，从qemu->kvm的流程梳理
  - [x] PATCH解析，寻找贡献点，适当与x86/arm对比
- [ ] 写一个guest-demo/用户态工具
  - [ ] 环境搭建与调试
  - [ ] 具体代码

---

**寻找PATCH贡献点：**

- [ ] 与arm64-sve对比，`fp/vector` 上下文的保存恢复机制，不同点在于没有引入per-cpu变量； 





# 1 CPU虚拟化分析

> 本文基于QEMU/KVM架构，分析CPU虚拟化的实现，软件版本如下：
>
> `qemu-8.1.0`：[Qemu source code (v8.1.0) - Bootlin](https://elixir.bootlin.com/qemu/v8.1.0/source)
>
> `linux-6.8`：[kvm_main.c - virt/kvm/kvm_main.c - Linux source code (v6.8) - Bootlin](https://elixir.bootlin.com/linux/v6.8/source/virt/kvm/kvm_main.c)
>
> * 对于riscv h扩展的相关内容，边梳理边补充；
> * 特定于中断(aia)、内存(gstage)、IO，一些复杂虚拟化子系统的实现，将在独立的文档中分析；
> * 文中列举的代码并不完整，只是截取了比较关键的部分；

## 1.1 概述

QEMU/KVM CPU虚拟化实现，可以概括为**”三个阶段，两种转换”**：

* **三个阶段**
  * **初始化阶段：**创建虚拟机、创建vCPU
  * **虚拟机运行阶段：**运行虚拟机指令
  * **异常处理阶段：**陷入Hypervisor，处理相应异常
* **两种转换**
  * 虚拟机陷入
  * 虚拟机陷出

![image-20240409095014197](https://cdn.jsdelivr.net/gh/MaskerDad/BlogImage@main/202404090950347.png)

## 1.2 KVM模块初始化

### 1）KVM初始化框架

从 `module_init(riscv_kvm_init)` 开始，代码在： `arch/riscv/kvm/main.c`：

<img src="https://cdn.jsdelivr.net/gh/MaskerDad/BlogImage@main/202404091314993.png" alt="module_init(riscv_kvm_init)" style="zoom: 200%;" />

* **架构相关**

  老版本内核，将架构相关的初始化代码，单独组织放入 `kvm_arch_init` 函数，新版本 `kvm_arch_init` 被移除，架构相关的代码直接放在KVM模块的初始化入口：`riscv_kvm_init`。 riscv硬件相关的初始化，包括：

  * 检查riscv扩展的支持情况，包括：h扩展是否支持、SBI版本、SBI_RFENCE支持；
  * 对riscv h扩展支持的 `gstage` 页表，进行基础设置，包括：MODE、VMID设置；
  * KVM模拟了riscv-aia相关组件(APLIC/IMSIC)，进行一些初始化设置；

* **KVM公共部分**

  这里说的公共，只是说最外层的接口相同，这其中有相当一部分函数，最终会调用到riscv特定的实现。下面依次来看：

  * **电源管理：**`cpuhp_setup_state_nocalls/register_syscore_ops(&kvm_syscore_ops)` 

    > 由于在cpu热插拔和系统休眠唤醒流程中，需要执行cpu的offline和online状态转换，因此对于需要控制cpu的相关模块，在这一流程中需要正确管理本模块的cpu状态设置。在电源管理流程中，相关模块可以向电源管理模块注册回调，当对应的电源管理事件发生时，该回调函数将会被调用。
    >
    > 其中`cpuhp_setup_state_nocalls`用于注册cpu热插拔时的回调，`register_syscore_op`用于注册系统休眠唤醒时的回调，它们最终都由 `kvm_arch_hardware_enable` 和 `kvm_arch_hardware_disable` 实现，用于在cpu下线时关闭hypervisor，并在cpu上线时重新初始化hypervisor。

  * **创建特定的slab：**`kmem_cache_create_usercopy/kvm_async_pf_init`

    > 资源分配，这两个函数，都是创建slab缓存，用于内核对象的分配。

  * **基于eventfd的中断通知机制**：`kvm_irqfd_init`

    > 为eventfd创建一个全局的工作队列，它用于在虚拟机被关闭时，关闭所有与其相关的irqfd，并等待该操作完成。

  * **宿主机调度vCPU：**`kvm_preempt_ops.sched_in/sched_out`

    > 站在host的角度看，vcpu只是其创建的一个普通线程，因此它也需要被host os的调度器管理。当为vcpu线程分配的时间片用完以后，需要让出物理cpu。当vcpu再一次被调度时，其又需要切入guest运行。因此，在vcpu相关的线程切换时，会同时涉及以下两部分上下文：
    >
    > * vcpu所在的普通线程上下文
    > * vcpu guest和host之间切换的上下文
    >
    > 那么如何在切换vcpu线程时，触发guest和host的切入切出操作呢？让我们想一下内核的一贯做法，比如：内核在执行某操作时需要其它模块配合，它就可以提供一个notifier，需要配合的模块将自己的回调函数注册到该notifier中，当该操作实际执行时可以遍历并执行notifier中已注册的函数，从而使对该操作感兴趣的模块，在其回调函数中定制自身的逻辑。
    >
    > 为了使被调度线程在调度时能执行其特定的函数，调度器也为每个线程提供了一个通知链preempt_notifiers。因此vcpu可以向preempt_notifiers注册一个通知，在线程被sched out或sched in时，调度器将调用其所注册的通知处理函数。而vcpu只需要在通知处理函数中实现vcpu的切入切出操作即可。流程图如下：
    >
    > ![img](https://pic1.zhimg.com/v2-ebebe7c47fbb7a7f15f359b6b1d74a4c_b.jpg)

  * **Debugfs子系统：**`kvm_init_debug`

    > 为kvm创建debugfs相关接口。

  * **设备直通框架VFIO初始化：**`kvm_vfio_ops_init`

    > 为vfio注册设备回调函数。

  * `kvm_gmem_init`

    > 2023/11 新引入的KVM ioctl `KVM_CREATE_GUEST_MEMFD`，后续单独分析。
    >
    > [PATCH v14 00/34\] KVM: guest_memfd() and per-page attributes - Paolo Bonzini (kernel.org)](https://lore.kernel.org/all/20231105163040.14904-1-pbonzini@redhat.com/)

  * `misc_register(&kvm_dev)`

    > 该函数用于注册字符设备驱动，在 `kvm_init` 中调用此函数完成注册，以便上层应用程序来使用kvm模块。
    >
    > 具体见 2) 小节

### 2）ioctl接口注册

kvm一共为用户态，提供了三组ioctl接口：`kvm ioctl`、`vm ioctl` 和 `vcpu ioctl`。它们分别为用于控制kvm全局、特定虚拟机以及特定vcpu相关的操作。其中kvm全局ioctl通过 `misc_register` 接口以字符设备的方式注册，而vm ioctl和vcpu ioctl则通过 `anon_inode_getfd` 接口以匿名inode方式注册。如下图所示：

![img](https://img2020.cnblogs.com/blog/1771657/202009/1771657-20200912222902627-2095696577.png)

- `kvm`：代表kvm内核模块，可以通过 `kvm_dev_ioctl` 来管理kvm版本信息，以及vm的创建等；
- `vm`：虚拟机实例，可以通过 `kvm_vm_ioctl` 函数来创建 `vcpu`，设置内存区间、分配中断等；
- `vcpu`：代表虚拟的CPU，可以通过 `kvm_vcpu_ioctl` 来启动或暂停CPU的运行、设置vcpu的寄存器等；

无论是qemu/kvmtool，使用以上KVM API的流程大致为：

>1. 打开 `/dev/kvm` 设备文件；
>2. `ioctl(xx, KVM_CREATE_VM, xx)` 创建虚拟机对象；
>3. `ioctl(xx, KVM_CREATE_VCPU, xx)` 为虚拟机创建vcpu对象；
>4. `ioctl(xx, KVM_RUN, xx)` 让vcpu运行起来；

## 1.3 虚拟机生命周期

- [x] 以下每部分，qemu/kvm放在一起

### 0) qemu整体流程

![img](https://img2020.cnblogs.com/blog/1771657/202010/1771657-20201011104601000-1844983544.png)

这个图借用了armv8的实现，但回调函数的注册流程是类似的。对于riscv来说，cpu具现化的函数为 `riscv_cpu_realize`，最终也调用到了 `qemu_init_vcpu`：

```c
static void riscv_cpu_realize(DeviceState *dev, Error **errp)
{
    CPUState *cs = CPU(dev);
    RISCVCPU *cpu = RISCV_CPU(dev);
    RISCVCPUClass *mcc = RISCV_CPU_GET_CLASS(dev);
    Error *local_err = NULL;

    cpu_exec_realizefn(cs, &local_err);
    if (local_err != NULL) {
        error_propagate(errp, local_err);
        return;
    }

    if (tcg_enabled()) {
        riscv_cpu_realize_tcg(dev, &local_err);
        if (local_err != NULL) {
            error_propagate(errp, local_err);
            return;
        }
    }

    riscv_cpu_finalize_features(cpu, &local_err);
    if (local_err != NULL) {
        error_propagate(errp, local_err);
        return;
    }

    riscv_cpu_register_gdb_regs_for_features(cs);

    qemu_init_vcpu(cs);
    cpu_reset(cs);

    mcc->parent_realize(dev, errp);
}
```

---

- [ ] 可以用gdb验证一下，enable-kvm后的callstack；

### 1) 创建虚拟机

![](https://cdn.jsdelivr.net/gh/MaskerDad/BlogImage@main/202404091411111.png)

KVM模块初始化后，QEMU即可打开 `/dev/kvm` 设备文件发起创建虚拟机的请求。虚拟机创建流程如下：

* QEMU侧解析命令行参数，创建相应类型的虚拟机结构体(QOM机制)；
* QEMU打开 `/dev/kvm` 设备文件，向KVM发起创建虚拟机的请求；
* KVM创建并初始化虚拟机结构体，并初始化硬件设置；
* 为虚拟机创建一个匿名文件，并将文件描述符返回给QEMU，后续QEMU可以通过虚拟机文件描述符调用虚拟机相应的接口，如创建vCPU等

> 本文只关注KVM_CREATE_VM这个ioctl，在 `kvm_init` 函数中调用了各种类型的ioctl，这里暂不分析。

---

下面重点关注 `kvm_create_vm` 函数：

```c
static struct kvm *kvm_create_vm(unsigned long type, const char *fdname)
{
	struct kvm *kvm = kvm_arch_alloc_vm();
	struct kvm_memslots *slots;

	kvm_eventfd_init(kvm);

	kvm->max_vcpus = KVM_MAX_VCPUS;
    
	/*
	 * Force subsequent debugfs file creations to fail if the VM directory
	 * is not created (by kvm_create_vm_debugfs()).
	 */
	kvm->debugfs_dentry = ERR_PTR(-ENOENT);

	for (i = 0; i < kvm_arch_nr_memslot_as_ids(kvm); i++) {
		for (j = 0; j < 2; j++) {
			slots = &kvm->__memslots[i][j];

			atomic_long_set(&slots->last_used_slot, (unsigned long)NULL);
			slots->hva_tree = RB_ROOT_CACHED;
			slots->gfn_tree = RB_ROOT;
			hash_init(slots->id_hash);
			slots->node_idx = j;

			/* Generations must be different for each address space. */
			slots->generation = i;
		}

		rcu_assign_pointer(kvm->memslots[i], &kvm->__memslots[i][0]);
	}

	for (i = 0; i < KVM_NR_BUSES; i++) {
		rcu_assign_pointer(kvm->buses[i],
			kzalloc(sizeof(struct kvm_io_bus), GFP_KERNEL_ACCOUNT));
		if (!kvm->buses[i])
			goto out_err_no_arch_destroy_vm;
	}

	r = kvm_arch_init_vm(kvm, type);
	if (r)
		goto out_err_no_arch_destroy_vm;

	r = hardware_enable_all();
	r = kvm_init_mmu_notifier(kvm);
	r = kvm_coalesced_mmio_init(kvm);
	r = kvm_create_vm_debugfs(kvm, fdname);
	r = kvm_arch_post_init_vm(kvm);

	mutex_lock(&kvm_lock);
	list_add(&kvm->vm_list, &vm_list);
	mutex_unlock(&kvm_lock);

	preempt_notifier_inc();
	kvm_init_pm_notifier(kvm);
    
	return kvm;
    
    	return kvm;

out_err:
	kvm_destroy_vm_debugfs(kvm);
out_err_no_debugfs:
	kvm_coalesced_mmio_free(kvm);
out_no_coalesced_mmio:
#ifdef CONFIG_KVM_GENERIC_MMU_NOTIFIER
	if (kvm->mmu_notifier.ops)
		mmu_notifier_unregister(&kvm->mmu_notifier, current->mm);
#endif
out_err_no_mmu_notifier:
	hardware_disable_all();
out_err_no_disable:
	kvm_arch_destroy_vm(kvm);
out_err_no_arch_destroy_vm:
	WARN_ON_ONCE(!refcount_dec_and_test(&kvm->users_count));
	for (i = 0; i < KVM_NR_BUSES; i++)
		kfree(kvm_get_bus(kvm, i));
	cleanup_srcu_struct(&kvm->irq_srcu);
out_err_no_irq_srcu:
	cleanup_srcu_struct(&kvm->srcu);
out_err_no_srcu:
	kvm_arch_free_vm(kvm);
	mmdrop(current->mm);
	return ERR_PTR(r);
}
```

* `kvm_arch_alloc_vm`：所有架构都默认调vzalloc，`x86/arm64` 有自己的实现；

* `kvm_arch_init_vm/kvm_arch_destroy_vm`

  ```c
  int kvm_arch_init_vm(struct kvm *kvm, unsigned long type)
  {
  	int r;
  
  	r = kvm_riscv_gstage_alloc_pgd(kvm);
  	if (r)
  		return r;
  
  	r = kvm_riscv_gstage_vmid_init(kvm);
  	if (r) {
  		kvm_riscv_gstage_free_pgd(kvm);
  		return r;
  	}
  
  	kvm_riscv_aia_init_vm(kvm);
  
  	kvm_riscv_guest_timer_init(kvm);
  
  	return 0;
  }
  
  void kvm_arch_destroy_vm(struct kvm *kvm)
  {
  	kvm_destroy_vcpus(kvm);
  
  	kvm_riscv_aia_destroy_vm(kvm);
  }
  
  void kvm_arch_vcpu_destroy(struct kvm_vcpu *vcpu)
  {
  	/* Cleanup VCPU AIA context */
  	kvm_riscv_vcpu_aia_deinit(vcpu);
  
  	/* Cleanup VCPU timer */
  	kvm_riscv_vcpu_timer_deinit(vcpu);
  
  	kvm_riscv_vcpu_pmu_deinit(vcpu);
  
  	/* Free unused pages pre-allocated for G-stage page table mappings */
  	kvm_mmu_free_memory_cache(&vcpu->arch.mmu_page_cache);
  
  	/* Free vector context space for host and guest kernel */
  	kvm_riscv_vcpu_free_vector_context(vcpu);
  }
  ```

  * `gstage:{pgd,vmid}`、aia、timer初始化；
  * `kvm_arch_destroy_vm` 遍历虚拟机所有vcpu，释放内存、缓存，最终调用 `kvm_arch_vcpu_destroy`;

* `hardware_enable_all`

  ```c
  static int hardware_enable_all(void)
  {
  	atomic_t failed = ATOMIC_INIT(0);
  	int r;
  
  	/*
  	 * Do not enable hardware virtualization if the system is going down.
  	 * If userspace initiated a forced reboot, e.g. reboot -f, then it's
  	 * possible for an in-flight KVM_CREATE_VM to trigger hardware enabling
  	 * after kvm_reboot() is called.  Note, this relies on system_state
  	 * being set _before_ kvm_reboot(), which is why KVM uses a syscore ops
  	 * hook instead of registering a dedicated reboot notifier (the latter
  	 * runs before system_state is updated).
  	 */
  	if (system_state == SYSTEM_HALT || system_state == SYSTEM_POWER_OFF ||
  	    system_state == SYSTEM_RESTART)
  		return -EBUSY;
  
  	/*
  	 * When onlining a CPU, cpu_online_mask is set before kvm_online_cpu()
  	 * is called, and so on_each_cpu() between them includes the CPU that
  	 * is being onlined.  As a result, hardware_enable_nolock() may get
  	 * invoked before kvm_online_cpu(), which also enables hardware if the
  	 * usage count is non-zero.  Disable CPU hotplug to avoid attempting to
  	 * enable hardware multiple times.
  	 */
  	cpus_read_lock();
  	mutex_lock(&kvm_lock);
  
  	r = 0;
  
  	kvm_usage_count++;
  	if (kvm_usage_count == 1) {
  		on_each_cpu(hardware_enable_nolock, &failed, 1);
  
  		if (atomic_read(&failed)) {
  			hardware_disable_all_nolock();
  			r = -EBUSY;
  		}
  	}
  
  	mutex_unlock(&kvm_lock);
  	cpus_read_unlock();
  
  	return r;
  }
  
  hardware_enable_nolock
      +-> __hardware_enable_nolock
      	+-> kvm_arch_hardware_enable
      
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
  ```

  从上面代码可以看到，`hardware_enable_all` 负责虚拟机创建或再次恢复时的硬件初始化设置，最终调到 `kvm_arch_hardware_enable`：

  * 将部分异常和在VS模式下响应的中断，代理到Guest OS；
  * `hcounteren` 控制VS模式下对性能计数器的访问，`0x02` 表示只允许访问 `time` 寄存器；
  * `hvip` 是riscv h扩展提供的虚拟中断注入接口，kvm层可以写VSEIP/VSTIP/VSSIP来主动挂起一个虚拟机中断，返回Guest时将响应中断；
  * `kvm_riscv_aia_enable` 初始化riscv-aia的硬件设置；

* `kvm_arch_post_init_vm`

  以下是x86实现，arm/riscv没有实现该函数：

  ```c
  /*
   * Called after the VM is otherwise initialized, but just before adding it to
   * the vm_list.
   */
  int __weak kvm_arch_post_init_vm(struct kvm *kvm)
  {
  	return 0;
  }
  
  // x86
  int kvm_arch_post_init_vm(struct kvm *kvm)
  {
  	return kvm_mmu_post_init_vm(kvm);
  }
  
  int kvm_mmu_post_init_vm(struct kvm *kvm)
  {
  	int err;
  
  	if (nx_hugepage_mitigation_hard_disabled)
  		return 0;
  
  	err = kvm_vm_create_worker_thread(kvm, kvm_nx_huge_page_recovery_worker, 0,
  					  "kvm-nx-lpage-recovery",
  					  &kvm->arch.nx_huge_page_recovery_thread);
  	if (!err)
  		kthread_unpark(kvm->arch.nx_huge_page_recovery_thread);
  
  	return err;
  }
  ```

* `kvm_init_mmu_notifier/kvm_init_pm_notifier`

  目前只有x86的 `kvm_arch_pm_notifier` 函数有具体实现。这是一个编译选项决定的函数，或者为空，或者注册一个MMU的通知事件，当Linux的内存子系统在进行一些页面管理的时候，会调用到这里注册的一些回调函数。

  ```c
  static int kvm_init_mmu_notifier(struct kvm *kvm)
  {
  	kvm->mmu_notifier.ops = &kvm_mmu_notifier_ops;
  	return mmu_notifier_register(&kvm->mmu_notifier, current->mm);
  }
  
  #ifdef CONFIG_HAVE_KVM_PM_NOTIFIER
  static int kvm_pm_notifier_call(struct notifier_block *bl,
  				unsigned long state,
  				void *unused)
  {
  	struct kvm *kvm = container_of(bl, struct kvm, pm_notifier);
  	return kvm_arch_pm_notifier(kvm, state);
  }
  
  static void kvm_init_pm_notifier(struct kvm *kvm)
  {
  	kvm->pm_notifier.notifier_call = kvm_pm_notifier_call;
  	/* Suspend KVM before we suspend ftrace, RCU, etc. */
  	kvm->pm_notifier.priority = INT_MAX;
  	register_pm_notifier(&kvm->pm_notifier);
  }
  
  static void kvm_destroy_pm_notifier(struct kvm *kvm)
  {
  	unregister_pm_notifier(&kvm->pm_notifier);
  }
  #else /* !CONFIG_HAVE_KVM_PM_NOTIFIER */
  ```

---

 `kvm_create_vm` 函数就分析到这了，其它的irqfd、debugfs等功能是KVM的公共特性。

### 2) 创建vCPU

#### qemu侧

![img](https://img2020.cnblogs.com/blog/1771657/202010/1771657-20201011104614683-924133375.png)

看一下 `kvm_arch_init_vcpu`，代码如下：

```c
int kvm_arch_init_vcpu(CPUState *cs)
{
    int ret = 0;
    RISCVCPU *cpu = RISCV_CPU(cs);

    qemu_add_vm_change_state_handler(kvm_riscv_vm_state_change, cs);

    if (!object_dynamic_cast(OBJECT(cpu), TYPE_RISCV_CPU_HOST)) {
        ret = kvm_vcpu_set_machine_ids(cpu, cs);
        if (ret != 0) {
            return ret;
        }
    }

    kvm_riscv_update_cpu_misa_ext(cpu, cs);
    kvm_riscv_update_cpu_cfg_isa_ext(cpu, cs);

    return ret;
}
```

发现并没有 `KVM_XXX_VCPU_INIT` 的ioctl调用，因为目前kvm-riscv暂未实现这个ioctl，所有的初始化都放在了 `KVM_CREATE_VCPU` 中。



#### kvm侧

![](https://cdn.jsdelivr.net/gh/MaskerDad/BlogImage@main/kvm_vm_ioctl_create_vcpu.png)

* 分配一页内存page给 `kvm->run`，在用户/内核间共享数据；
* `kvm_vcpu_init` 初始化vcpu的通用字段，包括：`vcpu_id/pid/kvm`、`preempted/ready/last_used_slot`、锁以及缓存资源初始化；
* riscv相关的vcpu初始化代码，全部在 `kvm_arch_vcpu_create` 函数中，目前并没有额外的 `kvm_arch_vcpu_init` 实现，这部分**需要重点分析；**
* `create_vcpu_fd`注册了`kvm_vcpu_fops` 操作函数集，并返回vcpu-fd给QEMU层。QEMU针对vcpu进行操作，设置`KVM_ARM_VCPU_XXX`，将触发`kvm_arch_vcpu_ioctl_vcpu_XXX` 的执行；

---

看 `kvm_arch_vcpu_create` 函数，有两部分内容需要关注：

1. 针对Guest初始状态，有一些关键的寄存器设置，包括 `kvm_cpu_context` 和 `kvm_vcpu_csr` 两部分，在进入Guest前应该怎样设置？
2. 最终调用 `kvm_riscv_reset_vcpu` 重置vcpu状态，该函数在哪些场景下被调用？

首先，看一下两个结构体：

```c
struct kvm_cpu_context {
	unsigned long zero;
	unsigned long ra;
	unsigned long sp;
	unsigned long gp;
	unsigned long tp;
	unsigned long t0;
	unsigned long t1;
	unsigned long t2;
	unsigned long s0;
	unsigned long s1;
	unsigned long a0;
	unsigned long a1;
	unsigned long a2;
	unsigned long a3;
	unsigned long a4;
	unsigned long a5;
	unsigned long a6;
	unsigned long a7;
	unsigned long s2;
	unsigned long s3;
	unsigned long s4;
	unsigned long s5;
	unsigned long s6;
	unsigned long s7;
	unsigned long s8;
	unsigned long s9;
	unsigned long s10;
	unsigned long s11;
	unsigned long t3;
	unsigned long t4;
	unsigned long t5;
	unsigned long t6;
	unsigned long sepc;
	unsigned long sstatus;
	unsigned long hstatus;
	union __riscv_fp_state fp;
	struct __riscv_v_ext_state vector;
};

struct kvm_vcpu_csr {
	unsigned long vsstatus;
	unsigned long vsie;
	unsigned long vstvec;
	unsigned long vsscratch;
	unsigned long vsepc;
	unsigned long vscause;
	unsigned long vstval;
	unsigned long hvip;
	unsigned long vsatp;
	unsigned long scounteren;
	unsigned long senvcfg;
};

int kvm_arch_vcpu_create(struct kvm_vcpu *vcpu)
{
	int rc;
	struct kvm_cpu_context *cntx;
	struct kvm_vcpu_csr *reset_csr = &vcpu->arch.guest_reset_csr;
    
	/* Setup reset state of shadow SSTATUS and HSTATUS CSRs */
	cntx = &vcpu->arch.guest_reset_context;
	cntx->sstatus = SR_SPP | SR_SPIE;
	cntx->hstatus = 0;
	cntx->hstatus |= HSTATUS_VTW;
	cntx->hstatus |= HSTATUS_SPVP;
	cntx->hstatus |= HSTATUS_SPV;

	//...

	/* Reset VCPU */
	kvm_riscv_reset_vcpu(vcpu);

	return 0;
}
```

先看第一个问题，一些特殊寄存器的设置，包括：

* `cntx->sstatus = SR_SPP | SR_SPIE`、`cntx->hstatus |= HSTATUS_SPV`

  执行sret指令后，切入Guest，CPU根据 `sstatus.SPP/hstatus.SPV`，特权模式切换为VS-Mode，同时SPIE值写入sstatus.SIE中，相当于打开Host的S态全局中断使能。

* `cntx->hstatus |= HSTATUS_VTW`

  hstatus.{vtsr, vtm, vtvm}和mstatus中的tsr, vtm, vtvm差不多，用于控制是否拦截vs-mode的相关操作（并抛出异常），VTW用于拦截WFI指令，触发虚拟指令异常（而不是非虚拟化模式下的非法指令异常）。

* `cntx->hstatus |= HSTATUS_SPVP`

  首次进入Guest前的硬件设置，应该假定为刚从Guest陷入的状态，因此SPVP应设置为1，其全称为：`Supervisor Previous Virtual Privilege`，解释为“虚拟化模式下的之前特权级”，从名字上就可以知道，非虚拟化模式下的陷入(V=0) 对SPVP没有影响。引入SPVP，主要是为了实现在U模式下，进行合法的VU/VS访问。

  下面是riscv-h-spec的相关解释：

  >The hypervisor virtual-machine load and store instructions are valid only in M-mode or HS-mode,
  >or in U-mode when hstatus.HU=1. Each instruction performs an explicit memory access as though
  >V=1; i.e., with the address translation and protection, and the endianness, that apply to memory
  >accesses in either VS-mode or VU-mode. Field SPVP of hstatus controls the privilege level of the
  >access. The explicit memory access is done as though in VU-mode when SPVP=0, and as though
  >in VS-mode when SPVP=1. As usual when V=1, two-stage address translation is applied, and the
  >HS-level sstatus.SUM is ignored. HS-level sstatus.MXR makes execute-only pages readable for
  >both stages of address translation (VS-stage and G-stage), whereas vsstatus.MXR affects only
  >the first translation stage (VS-stage).
  >
  >Field HU (Hypervisor in U-mode) controls whether the virtual-machine load/store instructions,
  >HLV, HLVX, and HSV, can be used also in U-mode. When HU=1, these instructions can be
  >executed in U-mode the same as in HS-mode. When HU=0, all hypervisor instructions cause an
  >illegal instruction trap in U-mode.
  >
  >When V=1 and a trap is taken into HS-mode, bit SPVP (Supervisor Previous Virtual Privilege)
  >is set to the nominal privilege mode at the time of the trap, the same as sstatus.SPP. But if
  >V=0 before a trap, SPVP is left unchanged on trap entry. SPVP controls the effective privilege of
  >explicit memory accesses made by the virtual-machine load/store instructions, HLV, HLVX, and
  >HSV.
  >
  >Without SPVP, if instructions HLV, HLVX, and HSV looked instead to sstatus.SPP for the
  >effective privilege of their memory accesses, then, even with HU=1, U-mode could not access
  >virtual machine memory at VS-level, because to enter U-mode using SRET always leaves SPP=0.
  >Unlike SPP, field SPVP is untouched by transitions back-and-forth between HS-mode and Umode.

  Hypervisor虚拟机的加载和存储指令，仅在M模式或HS模式中有效，或在当hstatus.HU=1时在U模式中有效。每个指令执行显式的内存访问，就好像V=1。即，具有适用于VS模式或VU模式中的内存访问的地址翻译和保护，以及字节序。hstatus的字段SPVP控制访问的特权级别。当SPVP=0时，显式的内存访问就像在VU模式中一样进行，当SPVP=1时，就像在VS模式中一样进行。

  字段 HU 控制虚拟机的载入/存储指令 HLV、HLVX 和 HSV 是否也可以在 U 模式中使用。当 HU=1 时，这些指令可以在 U 模式中执行，就像在 HS 模式中一样。当 HU=0 时，所有超级监控程序指令在 U 模式中都会导致非法指令陷阱。

  当V=1且陷入HS模式时，SPVP被设置为陷阱发生时的标准特权模式，与sstatus.SPP相同。但如果在陷阱发生之前V=0，那么在陷入时SPVP将保持不变。SPVP控制着，虚拟机加载/存储指令HLV、HLVX和HSV所进行的显式内存访问的有效特权。

  **注：**假设没有SPVP，如果指令HLV、HLVX和HSV查找sstatus.SPP来确定其内存访问的有效特权级别，即使在HU=1的情况下，U模式也无法在VS级别访问虚拟机内存，因为使用SRET进入U模式总是使SPP=0。与SPP不同，SPVP字段在HS模式和U模式之间来回转换时不受影响。

---

第二个问题，我们先找到 `kvm_riscv_reset_vcpu` 的所有调用点，以及代码：

```c
// arch/riscv/kvm/vcpu.c
kvm_arch_vcpu_create
    +-> kvm_riscv_reset_vcpu
    
kvm_riscv_check_vcpu_requests
    +-> if (kvm_check_request(KVM_REQ_VCPU_RESET, vcpu))
			kvm_riscv_reset_vcpu(vcpu);

kvm_sbi_hsm_vcpu_start
    +-> kvm_make_request(KVM_REQ_VCPU_RESET, target_vcpu);

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
	kvm_riscv_vcpu_sbi_sta_reset(vcpu);

	/* Reset the guest CSRs for hotplug usecase */
	if (loaded)
		kvm_arch_vcpu_load(vcpu, smp_processor_id());
	put_cpu();
}
```

- [ ] 关于 `kvm_arch_vcpu_load/kvm_arch_vcpu_put` 在该函数中的作用？
  - [ ] [PATCH 6/6\] RISC-V: Add SBI HSM extension in KVM - Atish Patra (kernel.org)](https://lore.kernel.org/all/20200803175846.26272-7-atish.patra@wdc.com/)
  - [ ] [smp多核启动（riscv架构） - 知乎 (zhihu.com)](https://zhuanlan.zhihu.com/p/653590588)
  - [ ] 当Guest发起SBI Call，KVM也不会跳出ioctl run的内循环，不会调到外层的 `vcpu_load`，因此这里必须加载一次；但 `kvm_arch_vcpu_put` 还是很奇怪？？？
  - [ ] we want to do a full put if  we were loaded (handling a request) and load the values back at the end of  the function。[[PATCH 1/5\] KVM: arm/arm64: Reset the VCPU without preemption and vcpu state loaded (columbia.edu)](https://lists.cs.columbia.edu/pipermail/kvmarm/2019-February/034725.html)
  - [ ] [[PATCH 1/5\] KVM: arm/arm64: Reset the VCPU without preemption and vcpu state loaded (columbia.edu)](https://lists.cs.columbia.edu/pipermail/kvmarm/2019-January/034288.html)

### 3) vCPU运行

#### qemu侧

![img](https://img2020.cnblogs.com/blog/1771657/202010/1771657-20201011104644801-1443039913.png)

- QEMU中为每一个vcpu创建一个用户线程，完成了vcpu的初始化后，便进入了vcpu的运行，而这是通过 `kvm_cpu_exec` 函数来完成的；
- `kvm_cpu_exec` 函数中，调用 `kvm_vcpu_ioctl(,KVM_RUN,)` 来让底层的物理CPU进行运行，并且监测VM的退出，退出原因就存放在`kvm_run->exit_reason` 中，也就是上文中提到过的应用层与底层交互的机制；

---

#### kvm侧

https://elixir.bootlin.com/linux/v6.8/C/ident/kvm_arch_vcpu_ioctl_run

用户层通过 `KVM_RUN` 命令，将触发KVM模块中 `kvm_arch_vcpu_ioctl_run` 函数的执行：

```c
kvm_arch_vcpu_ioctl_run
   	+-> kvm_riscv_vcpu_setup_config(vcpu); 	 //首次运行加载一次
	+-> vcpu->arch.ran_atleast_once = true;  //标记vCPU至少运行过一次
    +-> switch (run->exit_reason)			 //处理用户空间或内核的mmio、sbi、csr模拟值
        +-> kvm_riscv_vcpu_mmio_return
        +-> kvm_riscv_vcpu_sbi_return
        +-> kvm_riscv_vcpu_csr_return
    +-> vcpu_load
       	+-> kvm_arch_vcpu_load				 	  //a)
    +-> while(ret > 0)
        +-> xfer_to_guest_mode_handle_work(vcpu); //返回guest前检查并处理ti_flag
        +-> kvm_riscv_gstage_vmid_update
        +-> kvm_riscv_check_vcpu_requests
        +-> preempt_disable						  //禁抢占
        +-> kvm_riscv_vcpu_aia_update
        +-> local_irq_disable					  //禁中断
     	+-> vcpu->mode = IN_GUEST_MODE;
			/*
             * Ensure we set mode to IN_GUEST_MODE after we disable
             * interrupts and before the final VCPU requests check.
             * See the comment in kvm_vcpu_exiting_guest_mode() and
             * Documentation/virt/kvm/vcpu-requests.rst
             */
        +-> kvm_riscv_vcpu_flush_interrupts
        +-> kvm_riscv_update_hvip
        +-> kvm_riscv_local_tlb_sanitize
        +-> guest_timing_enter_irqoff
        	/* enter guest */
        +-> kvm_riscv_vcpu_enter_exit
            +-> kvm_riscv_vcpu_swap_in_guest_state(vcpu);
        	+-> guest_state_enter_irqoff();
			+-> __kvm_riscv_switch_to(&vcpu->arch);		//b)
			+-> vcpu->arch.last_exit_cpu = vcpu->cpu;
			+-> guest_state_exit_irqoff();
			+-> kvm_riscv_vcpu_swap_in_host_state(vcpu);
        	/* exit guest */
		+-> vcpu->mode = OUTSIDE_GUEST_MODE;
		+-> /*
             * Save SCAUSE, STVAL, HTVAL, and HTINST because we might
             * get an interrupt between __kvm_riscv_switch_to() and
             * local_irq_enable() which can potentially change CSRs.
             */
            trap.sepc = vcpu->arch.guest_context.sepc;	
            trap.scause = csr_read(CSR_SCAUSE);
            trap.stval = csr_read(CSR_STVAL);
            trap.htval = csr_read(CSR_HTVAL);
            trap.htinst = csr_read(CSR_HTINST);
        +-> kvm_riscv_vcpu_sync_interrupts
        +-> local_irq_enable();							//c)
			local_irq_disable();
			guest_timing_exit_irqoff();
			local_irq_enable();
			preempt_enable();
        	/* 虚拟机退出处理 */
        +-> kvm_riscv_vcpu_exit
        	case EXC_INST_ILLEGAL/EXC_LOAD_MISALIGNED/EXC_STORE_MISALIGNED
            	+-> kvm_riscv_vcpu_trap_redirect
            case EXC_VIRTUAL_INST_FAULT
                +-> kvm_riscv_vcpu_virtual_insn
           	case EXC_INST_GUEST_PAGE_FAULT/
                 EXC_LOAD_GUEST_PAGE_FAULT/
                 EXC_STORE_GUEST_PAGE_FAULT
               	+-> gstage_page_fault
            case EXC_SUPERVISOR_SYSCALL
                +-> kvm_riscv_vcpu_sbi_ecall
    +-> vcpu_put
        +-> kvm_arch_vcpu_put						 	//a)
```

以上为kvm-riscv vcpu run的核心流程，重点部分标注为a)、b)、c)，需要单独分析：

* a) `kvm_arch_vcpu_load/kvm_arch_vcpu_put`：用于vcpu上下文切换，如vcpu调度
* b) `__kvm_riscv_switch_to`：用于vcpu host/guest world切换，guest入口
* c) `local_irq_enable/local_irq_disable`：处理host中断

#### `kvm_arch_vcpu_load/kvm_arch_vcpu_put`



#### `__kvm_riscv_switch_to`



#### `local_irq_enable/local_irq_disable`











# n guest-demo

[ez4yunfeng2/riscv-kvm-demo (github.com)](https://github.com/ez4yunfeng2/riscv-kvm-demo)

## n.1 环境搭建



## n.2 Sample Code

