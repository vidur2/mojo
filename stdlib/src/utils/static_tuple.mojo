# ===----------------------------------------------------------------------=== #
# Copyright (c) 2024, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #
"""Implements StaticTuple, a statically-sized uniform container.

You can import these APIs from the `utils` package. For example:

```mojo
from utils import StaticTuple
```
"""

from memory import Pointer

from utils import unroll

# ===----------------------------------------------------------------------===#
# Utilities
# ===----------------------------------------------------------------------===#


@always_inline
fn _set_array_elem[
    index: Int,
    size: Int,
    type: AnyRegType,
](
    val: type,
    array: Reference[
        __mlir_type[`!pop.array<`, size.value, `, `, type, `>`],
        __mlir_attr.`1 : i1`,
        _,
    ],
):
    """Sets the array element at position `index` with the value `val`.

    Parameters:
        index: the position to replace the value at.
        size: the size of the array.
        type: the element type of the array

    Args:
        val: the value to set.
        array: the array which is captured by reference.
    """
    var ptr = __mlir_op.`pop.array.gep`(
        array.get_legacy_pointer().address, index.value
    )
    Pointer(ptr).store(val)


@always_inline
fn _create_array[
    size: Int, type: AnyRegType
](lst: VariadicList[type]) -> __mlir_type[
    `!pop.array<`, size.value, `, `, type, `>`
]:
    """Sets the array element at position `index` with the value `val`.

    Parameters:
        size: the size of the array.
        type: the element type of the array

    Args:
        lst: the list of values to set.

    Returns:
        The array with values filled from the input list.
    """
    debug_assert(size == len(lst), "mismatch in the number of elements")

    if len(lst) == 1:
        return __mlir_op.`pop.array.repeat`[
            _type = __mlir_type[`!pop.array<`, size.value, `, `, type, `>`]
        ](lst[0])

    else:
        var array = __mlir_op.`kgen.undef`[
            _type = __mlir_type[`!pop.array<`, size.value, `, `, type, `>`]
        ]()

        @always_inline
        @parameter
        fn fill[idx: Int]():
            _set_array_elem[idx, size, type](lst[idx], array)

        unroll[fill, size]()
        return array


# ===----------------------------------------------------------------------===#
# StaticTuple
# ===----------------------------------------------------------------------===#


fn _static_tuple_construction_checks[size: Int]():
    """Checks if the properties in `StaticTuple` are valid.

    Validity right now is just ensuring the number of elements is > 0.

    Parameters:
      size: The number of elements.
    """
    constrained[size > 0, "number of elements in `StaticTuple` must be > 0"]()


@value
@register_passable("trivial")
struct StaticTuple[element_type: AnyRegType, size: Int](Sized):
    """A statically sized tuple type which contains elements of homogeneous types.

    Parameters:
        element_type: The type of the elements in the tuple.
        size: The size of the tuple.
    """

    alias type = __mlir_type[
        `!pop.array<`, size.value, `, `, Self.element_type, `>`
    ]
    var array: Self.type
    """The underlying storage for the static tuple."""

    @always_inline
    fn __init__(inout self):
        """Constructs an empty (undefined) tuple."""
        _static_tuple_construction_checks[size]()
        self.array = __mlir_op.`kgen.undef`[_type = Self.type]()

    @always_inline
    fn __init__(inout self, *elems: Self.element_type):
        """Constructs a static tuple given a set of arguments.

        Args:
            elems: The element types.
        """
        _static_tuple_construction_checks[size]()
        self.array = _create_array[size](elems)

    @always_inline
    fn __init__(inout self, values: VariadicList[Self.element_type]):
        """Creates a tuple constant using the specified values.

        Args:
            values: The list of values.
        """
        _static_tuple_construction_checks[size]()
        self.array = _create_array[size, Self.element_type](values)

    @always_inline("nodebug")
    fn __len__(self) -> Int:
        """Returns the length of the array. This is a known constant value.

        Returns:
            The size of the list.
        """
        return size

    @always_inline("nodebug")
    fn __getitem__[index: Int](self) -> Self.element_type:
        """Returns the value of the tuple at the given index.

        Parameters:
            index: The index into the tuple.

        Returns:
            The value at the specified position.
        """
        constrained[index < size]()
        var val = __mlir_op.`pop.array.get`[
            _type = Self.element_type,
            index = index.value,
        ](self.array)
        return val

    @always_inline("nodebug")
    fn __setitem__[index: Int](inout self, val: Self.element_type):
        """Stores a single value into the tuple at the specified index.

        Parameters:
            index: The index into the tuple.

        Args:
            val: The value to store.
        """
        constrained[index < size]()
        var tmp = self
        _set_array_elem[index, size, Self.element_type](val, tmp.array)
        self = tmp

    @always_inline("nodebug")
    fn __getitem__[intable: Intable](self, index: intable) -> Self.element_type:
        """Returns the value of the tuple at the given dynamic index.

        Parameters:
            intable: The intable type.

        Args:
            index: The index into the tuple.

        Returns:
            The value at the specified position.
        """
        var offset = int(index)
        debug_assert(offset < size, "index must be within bounds")
        # Copy the array so we can get its address, because we can't take the
        # address of 'self' in a non-mutating method.
        var arrayCopy = self.array
        var ptr = __mlir_op.`pop.array.gep`(
            Pointer.address_of(arrayCopy).address, offset.value
        )
        return Pointer(ptr).load()

    @always_inline("nodebug")
    fn __setitem__[
        intable: Intable
    ](inout self, index: intable, val: Self.element_type):
        """Stores a single value into the tuple at the specified dynamic index.

        Parameters:
            intable: The intable type.

        Args:
            index: The index into the tuple.
            val: The value to store.
        """
        var offset = int(index)
        debug_assert(offset < size, "index must be within bounds")
        var tmp = self
        var ptr = __mlir_op.`pop.array.gep`(
            Pointer.address_of(tmp.array).address, offset.value
        )
        Pointer(ptr).store(val)
        self = tmp


# ===----------------------------------------------------------------------===#
# Array
# ===----------------------------------------------------------------------===#


@value
struct InlineArray[ElementType: CollectionElement, size: Int](Sized):
    """A fixed-size sequence of size homogenous elements where size is a constant expression.

    Parameters:
        ElementType: The type of the elements in the array.
        size: The size of the array.
    """

    alias type = __mlir_type[
        `!pop.array<`, size.value, `, `, Self.ElementType, `>`
    ]
    var _array: Self.type
    """The underlying storage for the array."""

    @always_inline
    fn __init__(inout self):
        """This constructor will always cause a compile time error if used.
        It is used to steer users away from uninitialized memory.
        """
        constrained[
            False,
            (
                "Initialize with either a variadic list of arguments or a"
                " default fill element."
            ),
        ]()
        self._array = __mlir_op.`kgen.undef`[_type = Self.type]()

    @always_inline
    fn __init__(inout self, fill: Self.ElementType):
        """Constructs an empty array where each element is the supplied `fill`.

        Args:
            fill: The element to fill each index.
        """
        _static_tuple_construction_checks[size]()
        self._array = __mlir_op.`kgen.undef`[_type = Self.type]()

        @unroll
        for i in range(size):
            var ptr = self._get_reference_unsafe(i)
            initialize_pointee_copy(UnsafePointer[Self.ElementType](ptr), fill)

    @always_inline
    fn __init__(inout self, *elems: Self.ElementType):
        """Constructs an array given a set of arguments.

        Args:
            elems: The element types.
        """
        debug_assert(len(elems) == size, "Elements must be of length size")
        _static_tuple_construction_checks[size]()
        self._array = __mlir_op.`kgen.undef`[_type = Self.type]()

        @unroll
        for i in range(size):
            var ref = self._get_reference_unsafe(i)
            initialize_pointee_move(
                UnsafePointer[Self.ElementType](ref), elems[i]
            )

    @always_inline("nodebug")
    fn __len__(self) -> Int:
        """Returns the length of the array. This is a known constant value.

        Returns:
            The size of the list.
        """
        return size

    @always_inline("nodebug")
    fn _get_reference_unsafe[
        mutability: __mlir_type.i1,
        self_life: AnyLifetime[mutability].type,
    ](
        self: Reference[Self, mutability, self_life]._mlir_type, index: Int
    ) -> Reference[Self.ElementType, mutability, self_life]:
        """Get a reference to an element of self without checking index bounds.

        Users should opt for `__refitem__` instead of this method.
        """
        var ptr = __mlir_op.`pop.array.gep`(
            Reference(Reference(self)[]._array).get_legacy_pointer().address,
            index.value,
        )
        return Reference[Self.ElementType, mutability, self_life](
            UnsafePointer(ptr)[]
        )

    @always_inline("nodebug")
    fn __refitem__[
        mutability: __mlir_type.i1,
        self_life: AnyLifetime[mutability].type,
        IntableType: Intable,
    ](
        self: Reference[Self, mutability, self_life]._mlir_type,
        index: IntableType,
    ) -> Reference[Self.ElementType, mutability, self_life]:
        """Get a `Reference` to the element at the given index.

        Parameters:
            mutability: The inferred mutability of the reference.
            self_life: The inferred lifetime of the reference.
            IntableType: The inferred type of an intable argument.

        Args:
            index: The index of the item.

        Returns:
            A reference to the item at the given index.
        """
        debug_assert(-size <= int(index) < size, "Index must be within bounds.")
        var normalized_idx = int(index)
        if normalized_idx < 0:
            normalized_idx += size

        return Reference(self)[]._get_reference_unsafe[mutability, self_life](
            normalized_idx
        )

    @always_inline("nodebug")
    fn __refitem__[
        mutability: __mlir_type.i1,
        self_life: AnyLifetime[mutability].type,
        IntableType: Intable,
        index: IntableType,
    ](self: Reference[Self, mutability, self_life]._mlir_type) -> Reference[
        Self.ElementType, mutability, self_life
    ]:
        """Get a `Reference` to the element at the given index.

        Parameters:
            mutability: The inferred mutability of the reference.
            self_life: The inferred lifetime of the reference.
            IntableType: The inferred type of an intable argument.
            index: The index of the item.

        Returns:
            A reference to the item at the given index.
        """
        alias i = int(index)
        constrained[-size <= i < size, "Index must be within bounds."]()

        var normalized_idx = i

        @parameter
        if i < 0:
            normalized_idx += size

        return Reference(self)[]._get_reference_unsafe[mutability, self_life](
            normalized_idx
        )