This folder contains the changes over LLVM 21.1.4 to add an Lotus calling convention.

To build this modified LLVM, do the following:

cd /scratch/... # Pick a folder on a local SSD (build process is I/O intensive)
git clone --depth 1 --branch llvmorg-21.1.4 https://github.com/llvm/llvm-project.git
cd llvm-project
git apply $LOTUS_REPO_DIR/llvm_lotus/riscv_lotus_task_cc.patch
mkdir install
cmake -S llvm -B build -G Ninja -DCMAKE_BUILD_TYPE="Release" -DLLVM_ENABLE_PROJECTS="clang;lld" -DLLVM_ENABLE_LLD=ON -DLLVM_INSTALL_UTILS=ON -DCMAKE_INSTALL_PREFIX=`pwd`/install
ninja -C build install

Then, copy install wherever you want.

