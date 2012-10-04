#include <thrust/tuple.h>
#include <iostream>
#include "oet.h"
#include "bubble.h"
#include "transpose.h"
#include "memory.h"
#include "print_tuple.h"
#include <thrust/device_vector.h>

using namespace trove;

template<typename Value>
__global__ void test_transpose_indices(Value* r) {
    int global_index = threadIdx.x;
    Value warp_offsets;
    int rotation;
    c2r_compute_indices(warp_offsets, rotation);
    //r[global_index] = warp_offsets;
    Value data;
    data = counting_tuple<Value>::impl(
        global_index * thrust::tuple_size<Value>::value);
    
    c2r_warp_transpose(data, warp_offsets, rotation);
    r[global_index] = data;
}

template<int size, typename T>
__global__ void test_c2r_transpose(T* r) {
    typedef typename homogeneous_tuple<size, T>::type Value;
    typedef typename homogeneous_tuple<size, int>::type Indices;
    int global_index = threadIdx.x + blockDim.x * blockIdx.x;

    Indices warp_offsets;
    int rotation;
    c2r_compute_indices(warp_offsets, rotation);

    Value data;
    data = counting_tuple<Value>::impl(
        global_index * size);
    
    for(int i = 0; i < 1; i++) {
        c2r_warp_transpose(data, warp_offsets, rotation);
    }
    int warp_begin = threadIdx.x & (~WARP_MASK);
    int warp_idx = threadIdx.x & WARP_MASK;
    int warp_offset = (blockDim.x * blockIdx.x + warp_begin) * size;
    T* warp_ptr = r + warp_offset;
    warp_store(data, warp_ptr, warp_idx, 32);
}





template<int size, typename T>
__global__ void test_uncoalesced_store(T* r) {
    
    typedef typename homogeneous_tuple<size, T>::type Value;
    int global_index = threadIdx.x + blockDim.x * blockIdx.x;

    Value data = counting_tuple<Value>::impl(
        global_index * size);
    
    T* thread_ptr = r + global_index * size;
    uncoalesced_store(data, thread_ptr);
}



template<int size, typename T>
__global__ void test_shared_c2r_transpose(T* r) {
    typedef typename homogeneous_tuple<size, T>::type Value;

    int global_index = threadIdx.x + blockDim.x * blockIdx.x;
    int work_per_thread = thrust::tuple_size<Value>::value;
    extern __shared__ T smem[];
    
    Value data;
    data = counting_tuple<Value>::impl(
        global_index * work_per_thread);
    int warp_id = threadIdx.x >> 5;
    int warp_idx = threadIdx.x & WARP_MASK;

    for(int i = 0; i < 1; i++) {
        volatile T* thread_ptr = smem + threadIdx.x * work_per_thread;
        uncoalesced_store(data, thread_ptr);


        data = warp_load<Value>(smem + warp_id * WARP_SIZE * size,
                                warp_idx);
    }
    int warp_begin = threadIdx.x & (~WARP_MASK);
    int warp_offset = (blockDim.x * blockIdx.x + warp_begin) * size;
    T* warp_ptr = r + warp_offset;
    warp_store(data, warp_ptr, warp_idx, 32);
   
}



template<typename T>
void verify(thrust::device_vector<T>& d_r) {
    thrust::host_vector<T> h_r = d_r;
    bool fail = false;
    for(int i = 0; i < h_r.size(); i++) {
        if (h_r[i] != i) {
            std::cout << "  Fail: r[" << i << "] is " << h_r[i] << std::endl;
            fail = true;
        }
    }
    if (!fail) {
        std::cout << "Pass!" << std::endl;
    }
}

template<int i, typename Tail=thrust::null_type>
struct int_cons {
    static const int head = i;
    typedef Tail tail;
};

typedef
int_cons<2,
    int_cons<3,
    int_cons<4,
    int_cons<5,
    int_cons<7,
    int_cons<8,
    int_cons<9,
    thrust::null_type> > > > > > > c2r_arities;

template<int i>
void test_c2r_transpose() {
    int n_blocks = 15 * 8 * 100;
    int block_size = 256;
    thrust::device_vector<int> e(n_blocks*block_size*i);
    test_c2r_transpose<i>
        <<<n_blocks, block_size>>>(thrust::raw_pointer_cast(e.data()));
    verify(e); 
}

template<typename Cons>
struct test_c2r_transposes {
    static void impl() {
        std::cout << "Testing c2r transpose for " << Cons::head <<
            " elements per thread" << std::endl;
        test_c2r_transpose<Cons::head>();
        test_c2r_transposes<typename Cons::tail>::impl();
    }
};

template<>
struct test_c2r_transposes<thrust::null_type> {
    static void impl() {}
};
  
int main() {
    test_c2r_transposes<c2r_arities>::impl();  
}
    
