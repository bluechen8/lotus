/** $lic$
 * Copyright (C) 2024-2026 by Massachusetts Institute of Technology.
 *
 * This file is part of Lotus. Lotus is free software; you can redistribute it
 * and/or modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, version 2.
 */

#include <stdint.h>
#include <tuple>
#include <vector>
#include <bit>
#include <type_traits>
#include <assert.h>
#include <algorithm>
#include <bit>

#include <iostream>
#include <string_view>
#include <array>
#include <cstddef>

// template <typename T, std::size_t N>
// std::ostream& operator<<(std::ostream& os, const std::array<T, N>& arr) {
//     os << "{ ";
//     for (std::size_t i = 0; i < N; ++i) {
//         os << arr[i];
//         if (i < N - 1) {
//             os << ", ";
//         }
//     }
//     os << " }";
//     return os;
// }
template <typename T>
struct AsBytes {
    const T& ref;
};
template <typename T>
AsBytes<T> as_bytes(const T& obj) {
    return { obj };
}
template <typename T>
std::ostream& operator<<(std::ostream& os, const AsBytes<T>& wrapper) {
    const uint8_t* bytes = reinterpret_cast<const uint8_t*>(&wrapper.ref);
    os << "{ ";
    for (std::size_t i = 0; i < sizeof(T); ++i) {
        os << static_cast<int>(bytes[i]);
        if (i < sizeof(T) - 1) {
            os << ", ";
        }
    }
    os << " }";
    return os;
}

// Compile-time type name derivation, no RTTI needed, see https://stackoverflow.com/a/59522794
namespace impl
{
    template <typename T>
    [[nodiscard]] constexpr std::string_view RawTypeName()
    {
        #ifndef _MSC_VER
        return __PRETTY_FUNCTION__;
        #else
        return __FUNCSIG__;
        #endif
    }

    struct TypeNameFormat
    {
        std::size_t junk_leading = 0;
        std::size_t junk_total = 0;
    };

    constexpr TypeNameFormat type_name_format = []{
        TypeNameFormat ret;
        std::string_view sample = RawTypeName<int>();
        ret.junk_leading = sample.find("int");
        ret.junk_total = sample.size() - 3;
        return ret;
    }();
    static_assert(type_name_format.junk_leading != std::size_t(-1), "Unable to determine the type name format on this compiler.");

    template <typename T>
    static constexpr auto type_name_storage = []{
        std::array<char, RawTypeName<T>().size() - type_name_format.junk_total + 1> ret{};
        std::copy_n(RawTypeName<T>().data() + type_name_format.junk_leading, ret.size() - 1, ret.data());
        return ret;
    }();
}

template <typename T>
[[nodiscard]] constexpr std::string_view TypeName()
{
    return {impl::type_name_storage<T>.data(), impl::type_name_storage<T>.size() - 1};
}

template <typename T>
[[nodiscard]] constexpr const char *TypeNameCstr()
{
    return impl::type_name_storage<T>.data();
}

namespace taskflow {

template <typename T> struct TaskOut {
    size_t taskIdx;
    size_t outIdx;
};

// std::tuple wrapper
template<typename T>
struct TaskRetType;

template <class... Ts>
struct TaskRetType<std::tuple<Ts...>> {
    using type = std::tuple<TaskOut<Ts>...>;
};

// =====================================

// --- function_traits: pull return type and parameter types from a function type ---
template <typename> struct function_traits;

template <typename R, typename... Ps>
struct function_traits<R(Ps...)> {
  using return_type = R;
  using params_tuple = std::tuple<Ps...>;
  static constexpr std::size_t arity = sizeof...(Ps);
};

template <typename R, typename... Ps>
struct function_traits<R(*)(Ps...)> : function_traits<R(Ps...)> {};

// --- tuple utils: drop the first element ---
template <typename Tuple> struct tuple_drop_first;
template <typename T0, typename... Ts>
struct tuple_drop_first<std::tuple<T0, Ts...>> { using type = std::tuple<Ts...>; };
template <typename Tuple>
using tuple_drop_first_t = typename tuple_drop_first<Tuple>::type;

// --- binding check between function parameter P and Edge<A>'s A ---
// Base rule: allow T, T&, const T& to bind from an Edge<T> input.
// You can relax/strengthen this if needed.
template <typename P, typename A>
struct can_bind_param
  : std::bool_constant<std::is_same_v<std::remove_cvref_t<P>, A>> {};

// Helper to check all arguments pairwise: Param[i] vs Arg[i]
template <typename ParamsTuple, typename... As>
struct check_params_match;

template <typename... Ps, typename... As>
struct check_params_match<std::tuple<Ps...>, As...>
    : std::bool_constant<(sizeof...(Ps) == sizeof...(As)) &&
                         (can_bind_param<Ps, As>::value && ...)> {};


////////////////////////////////////

// See https://www.scs.stanford.edu/~dm/blog/param-pack.html, Using lambda expressions to capture packs
template<typename T>
auto genTaskOuts(const T &a, size_t taskIdx)
{
  return [&a, taskIdx]<std::size_t ...I>(std::index_sequence<I...>) {
    return std::tuple(decltype(std::get<I>(a)){taskIdx, I}...);
  }(std::make_index_sequence<std::tuple_size_v<T>>{});
}

// Value/edge types
inline size_t numEdges = 0;

template <typename T> struct Edge {
    const size_t idx;
    const T initValue{};
    const uint8_t cycleDelta;
    TaskOut<T> writer;

    Edge(T initValue_, uint8_t cycleDelta_) :
        idx(numEdges++), initValue(initValue_), cycleDelta(cycleDelta_), writer({-1ul,-1ul})
    {
        std::cout << "Edge\n edgeIdx: " << idx << "\n type: " << TypeName<T>() << "\n initValue: " << as_bytes(initValue) << "\n cycleDelta: " << ((int) cycleDelta) << "\n";
    }

    Edge(std::string_view filename_, uint8_t cycleDelta_) :
        idx(numEdges++), cycleDelta(cycleDelta_), writer({-1ul,-1ul})
    {
        std::cout << "Edge\n edgeIdx: " << idx << "\n type: " << TypeName<T>() << "\n filename: " << filename_ << "\n cycleDelta: " << ((int) cycleDelta) << "\n";
    }

    // Edge<T>& operator= (TaskOut<T>& writer_) {
    //     if (writer.taskIdx != -1ul) {
    //         std::cout << "ERROR: Double-write, edgeIdx: " << idx <<
    //             " writer: " << writer.taskIdx << " " << writer.outIdx <<
    //             " newWriter: " << writer_.taskIdx << " " << writer_.outIdx << "\n";
    //     }
    //     assert(writer.taskIdx == -1ul);
    //     writer = writer_;
    //     std::cout << "Write\n edgeIdx: " << idx << "\n writerTaskIdx: " << writer.taskIdx << "\n writerOutIdx: " << writer.outIdx << "\n";
    //     return *this;
    // }
};

template <typename T> struct Reg : public Edge<T> {
    Reg(T initValue_) : Edge<T>(initValue_, 1) {}
    Reg(std::string_view filename_) : Edge<T>(filename_, 1) {}

    // Reg<T>& operator= (TaskOut<T>& writer) {
    //     Edge<T>::operator=(writer);
    //     return *this;
    // }
};

template <typename T> struct Wire : public Edge<T> {
    Wire() : Edge<T>(T{}, 0) {}
};

// Tasks
inline size_t numTasks = 0;

// Templated helper
template <typename T, size_t... seq> void printTupleTypes(std::index_sequence<seq...> s) {
    size_t n = 0;
    ((std::cout << TypeName<std::tuple_element_t<seq, T> >() << (++n != std::tuple_size_v<T>? "; " : "")), ...);
}

template <typename F, F* f, typename... Args>
void
taskImpl(const char* name, Edge<Args>... args) {
  using Traits      = function_traits<F>;
  // using FnRetType   = typename Traits::return_type;
  // using RetType     = typename TaskRetType<FnRetType>::type;
  using UserParams   = typename Traits::params_tuple;      // (a0, a1, ...)
  // using UserParams  = tuple_drop_first_t<AllParams>;      // (a0, a1, ...)

  static_assert(Traits::arity >= 1, "Function must have at least one parameter.");
  static_assert(sizeof...(Args) == std::tuple_size_v<UserParams>,
                "Number of Edge<...> inputs must match the function's non-cycle parameters.");
  static_assert(check_params_match<UserParams, Args...>::value,
                "Edge<T> input type does not match/bind to the function's parameter type (ignoring ref/const).");

  size_t idx = numTasks++;

  std::cout << "Task\n taskIdx: " << idx << "\n fn: " << name;

  std::cout << "\n inTypes: ";
  []<std::size_t... I>(std::index_sequence<I...>) {
    std::size_t n = 0;
    ((std::cout << TypeName<std::tuple_element_t<I, UserParams>>()
                << (++n != sizeof...(I) ? "; " : "")), ...);
  }(std::make_index_sequence<std::tuple_size_v<UserParams>>{});

  std::cout << "\n inEdges: ";
  size_t n = 0;
  ((std::cout << args.idx << (++n != sizeof...(Args) ? "; " : "")), ...);

  // std::cout << "\n outTypes: ";
  // printTupleTypes<FnRetType>(std::make_index_sequence<std::tuple_size_v<FnRetType>>{});
  std::cout << "\n";

}

/* Syntactic sugar */
#define task(f, ...) \
    taskImpl<std::remove_reference_t<decltype(f)>, f >( #f,  __VA_ARGS__)


void next_task_label(const std::string& lab) {
  std::cout << "NextTaskLabel\n";
  std::cout << "  label: " << lab << "\n";
}

void next_var_is_unroll() { std::cout << "NextVarIsUnroll\n"; }

void new_part_group() { std::cout << "NewPart\n"; }

void new_coarse_group() { std::cout << "NewCoarse\n"; }


};
