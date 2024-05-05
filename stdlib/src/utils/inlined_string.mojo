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

"""Implements a string that has a small-string optimization which
   avoids heap allocations for short strings.
"""

from sys import sizeof

from memory import memcpy, LegacyPointer

from collections import Optional

from utils import InlineArray, Variant
from utils._format import ToFormatter


# ===----------------------------------------------------------------------===#
# InlinedString
# ===----------------------------------------------------------------------===#


@value
struct InlinedString(Sized, Stringable, CollectionElement):
    """A string that performs small-string optimization to avoid heap allocations for short strings.
    """

    alias SMALL_CAP: Int = 24

    """The number of bytes of string data that can be stored inline in this
    string before a heap allocation is required.

    If constructed from a heap allocated String that string will be used as the
    layout of this string, even if the given string would fit within the
    small-string capacity of this type."""

    alias Layout = Variant[String, _FixedString[Self.SMALL_CAP]]

    var _storage: Self.Layout

    # ===------------------------------------------------------------------===#
    # Constructors
    # ===------------------------------------------------------------------===#

    fn __init__(inout self):
        """Constructs a new empty string."""
        var fixed = _FixedString[Self.SMALL_CAP]()
        self._storage = Self.Layout(fixed^)

    fn __init__(inout self, literal: StringLiteral):
        """Constructs a InlinedString value given a string literal.

        Args:
            literal: The input constant string.
        """

        if len(literal) <= Self.SMALL_CAP:
            try:
                var fixed = _FixedString[Self.SMALL_CAP](literal)
                self._storage = Self.Layout(fixed^)
            except e:
                abort(
                    "unreachable: Construction of FixedString of validated"
                    " string failed"
                )
                # TODO(#11245):
                #   When support for "noreturn" functions is added,
                #   this false initialization of this type should be unnecessary.
                self._storage = Self.Layout(String(""))
        else:
            var heap = String(literal)
            self._storage = Self.Layout(heap^)

    fn __init__(inout self, owned heap_string: String):
        """Construct a new small string by taking ownership of an existing
        heap-allocated String.

        Args:
            heap_string: The heap string to take ownership of.
        """
        self._storage = Self.Layout(heap_string^)

    # ===------------------------------------------------------------------=== #
    # Trait Interfaces
    # ===------------------------------------------------------------------=== #

    fn __len__(self) -> Int:
        if self._is_small():
            return len(self._storage.get[_FixedString[Self.SMALL_CAP]]()[])
        else:
            debug_assert(
                self._storage.isa[String](),
                "expected non-small string variant to be String",
            )
            return len(self._storage.get[String]()[])

    fn __str__(self) -> String:
        if self._is_small():
            return str(self._storage.get[_FixedString[Self.SMALL_CAP]]()[])
        else:
            return self._storage.get[String]()[]

    fn __iadd__(inout self, literal: StringLiteral):
        """Appends another string to this string.

        Args:
            literal: The string to append.
        """
        self.__iadd__(StringRef(literal))

    fn __iadd__(inout self, string: String):
        """Appends another string to this string.

        Args:
            string: The string to append.
        """
        self.__iadd__(string._strref_dangerous())

    fn __iadd__(inout self, strref: StringRef):
        """Appends another string to this string.

        Args:
            strref: The string to append.
        """
        var total_len = len(self) + len(strref)

        # NOTE: Not guaranteed that we're in the small layout even if our
        #       length is shorter than the small capacity.

        if not self._is_small():
            self._storage.get[String]()[] += strref
        elif total_len < Self.SMALL_CAP:
            try:
                self._storage.get[_FixedString[Self.SMALL_CAP]]()[] += strref
            except e:
                abort(
                    "unreachable: InlinedString append to FixedString failed: "
                    + str(e),
                )
        else:
            # We're currently in the small layout but must change to the
            # big layout.

            # Begin by heap allocating enough space to store the combined
            # string.
            var buffer = List[Int8](capacity=total_len)

            var buffer_ptr = rebind[DTypePointer[DType.int8]](buffer.data)

            # Copy the bytes from the current small string layout
            memcpy(
                buffer_ptr,
                self._storage.get[_FixedString[Self.SMALL_CAP]]()[].as_ptr(),
                len(self),
            )

            # Copy the bytes from the additional string.
            memcpy(buffer_ptr + len(self), strref.data, len(strref))

            # Record that we've initialized `total_len` count of elements
            # in `buffer`
            buffer.size = total_len

            # Add the NUL byte
            buffer.append(0)

            self._storage = Self.Layout(String(buffer^))

    fn __add__(self, other: StringLiteral) -> Self:
        """Construct a string by appending another string at the end of this string.

        Args:
            other: The string to append.

        Returns:
            A new string containing the concatenation of `self` and `other`.
        """

        var string = self
        string += StringRef(other)
        return string

    fn __add__(self, other: String) -> Self:
        """Construct a string by appending another string at the end of this string.

        Args:
            other: The string to append.

        Returns:
            A new string containing the concatenation of `self` and `other`.
        """

        var string = self
        string += other._strref_dangerous()
        return string

    fn __add__(self, other: InlinedString) -> Self:
        """Construct a string by appending another string at the end of this string.

        Args:
            other: The string to append.

        Returns:
            A new string containing the concatenation of `self` and `other`.
        """

        var string = self
        string += other._strref_dangerous()
        return string

    # ===------------------------------------------------------------------=== #
    # Methods
    # ===------------------------------------------------------------------=== #

    fn _is_small(self) -> Bool:
        """Returns True if this string is currently in the small-string
        opimization layout."""
        var res: Bool = self._storage.isa[_FixedString[Self.SMALL_CAP]]()

        return res

    fn as_ptr(self) -> DTypePointer[DType.int8]:
        """Returns a pointer to the bytes of string data.

        Returns:
            The pointer to the underlying memory.
        """

        if self._is_small():
            return self._storage.get[_FixedString[Self.SMALL_CAP]]()[].as_ptr()
        else:
            return self._storage.get[String]()[]._as_ptr()

    fn _strref_dangerous(self) -> StringRef:
        """
        Returns an inner pointer to the string as a StringRef.
        This functionality is extremely dangerous because Mojo eagerly releases
        strings.  Using this requires the use of the _strref_keepalive() method
        to keep the underlying string alive long enough.
        """
        return StringRef {data: self.as_ptr(), length: len(self)}

    fn _strref_keepalive(self):
        """
        A noop that keeps `self` alive through the call.  This
        can be carefully used with `_strref_dangerous()` to wield inner pointers
        without the string getting deallocated early.
        """
        pass


# ===----------------------------------------------------------------------===#
# __FixedString
# ===----------------------------------------------------------------------===#


@value
struct _FixedString[CAP: Int](
    Sized, Stringable, Formattable, ToFormatter, CollectionElement
):
    """A string with a fixed available capacity.

    The string data is stored inline in this structs memory layout.

    Parameters:
        CAP: The fixed-size count of bytes of string storage capacity available.
    """

    var buffer: _ArrayMem[Int8, CAP]
    """The underlying storage for the fixed string."""
    var size: Int
    """The number of elements in the vector."""

    # ===------------------------------------------------------------------===#
    # Constructors
    # ===------------------------------------------------------------------===#

    fn __init__(inout self):
        """Constructs a new empty string."""
        self.buffer = _ArrayMem[Int8, CAP]()
        self.size = 0

    @always_inline
    fn __init__(inout self, literal: StringLiteral) raises:
        """Constructs a FixedString value given a string literal.

        Args:
            literal: The input constant string.
        """
        if len(literal) > CAP:
            raise Error(
                "String literal (len="
                + str(len(literal))
                + ") is longer than FixedString capacity ("
                + CAP
                + ")"
            )

        self.buffer = _ArrayMem[Int8, CAP]()
        self.size = len(literal)

        memcpy(self.buffer.as_ptr(), literal.data(), len(literal))

    # ===------------------------------------------------------------------=== #
    # Trait Interfaces
    # ===------------------------------------------------------------------=== #

    @always_inline
    fn __str__(self) -> String:
        return String(self._strref_dangerous())

    fn __len__(self) -> Int:
        return self.size

    fn __iadd__(inout self, literal: StringLiteral) raises:
        """Appends another string to this string.

        Args:
            literal: The string to append.
        """
        self.__iadd__(StringRef(literal))

    fn __iadd__(inout self, string: String) raises:
        """Appends another string to this string.

        Args:
            string: The string to append.
        """
        self.__iadd__(string._strref_dangerous())

    @always_inline
    fn __iadd__(inout self, strref: StringRef) raises:
        """Appends another string to this string.

        Args:
            strref: The string to append.
        """
        var err = self._iadd_non_raising(strref)
        if err:
            raise err.value()[]

    fn _iadd_non_raising(inout self, strref: StringRef) -> Optional[Error]:
        var total_len = len(self) + len(strref)

        # Ensure there is sufficient capacity to append `strref`
        if total_len > CAP:
            return Optional(
                Error(
                    "Insufficient capacity to append len="
                    + str(len(strref))
                    + " string to len="
                    + str(len(self))
                    + " FixedString with capacity="
                    + str(CAP),
                )
            )

        # Append the bytes from `strref` at the end of the current string
        memcpy(self.buffer.as_ptr() + len(self), strref.data, len(strref))

        self.size = total_len

        return None

    fn format_to(self, inout writer: Formatter):
        writer.write_str(self._strref_dangerous())

    fn _unsafe_to_formatter(inout self) -> Formatter:
        fn write_to_string(ptr0: UnsafePointer[NoneType], strref: StringRef):
            var ptr: UnsafePointer[Self] = ptr0.bitcast[Self]()

            # FIXME(#37990):
            #   Use `ptr[] += strref` and remove _iadd_non_raising after
            #   "failed to fold operation lit.try" is fixed.
            # try:
            #     ptr[] += strref
            # except e:
            #     abort("error formatting to FixedString: " + str(e))
            var err = ptr[]._iadd_non_raising(strref)
            if err:
                abort("error formatting to FixedString: " + str(err.value()[]))

        return Formatter(
            write_to_string,
            # Arg data
            UnsafePointer.address_of(self).bitcast[NoneType](),
        )

    # ===------------------------------------------------------------------=== #
    # Methods
    # ===------------------------------------------------------------------=== #

    @staticmethod
    fn format_sequence[*Ts: Formattable](*args: *Ts) -> Self:
        """
        Construct a string by concatenating a sequence of formattable arguments.

        Args:
            args: A sequence of formattable arguments.

        Parameters:
            Ts: The types of the arguments to format. Each type must be satisfy
              `Formattable`.

        Returns:
            A string formed by formatting the argument sequence.
        """

        var output = Self()
        var writer = output._unsafe_to_formatter()

        @parameter
        fn write_arg[T: Formattable](arg: T):
            arg.format_to(writer)

        args.each[write_arg]()

        return output^

    fn as_ptr(self) -> DTypePointer[DType.int8]:
        """Retrieves a pointer to the underlying memory.

        Returns:
            The pointer to the underlying memory.
        """
        return self.buffer.as_ptr()

    fn _strref_dangerous(self) -> StringRef:
        """
        Returns an inner pointer to the string as a StringRef.
        This functionality is extremely dangerous because Mojo eagerly releases
        strings.  Using this requires the use of the _strref_keepalive() method
        to keep the underlying string alive long enough.
        """
        return StringRef {data: self.as_ptr(), length: len(self)}

    fn _strref_keepalive(self):
        """
        A noop that keeps `self` alive through the call.  This
        can be carefully used with `_strref_dangerous()` to wield inner pointers
        without the string getting deallocated early.
        """
        pass


# ===----------------------------------------------------------------------===#
# _ArrayMem
# ===----------------------------------------------------------------------===#


@value
struct _ArrayMem[ElementType: AnyRegType, SIZE: Int](Sized):
    """A fixed-sized, homogenous, contiguous, inline collection type.

    Parameters:
        ElementType: The type of the elements in the array.
        SIZE: The fixed number of elements stored in the array.
    """

    var storage: InlineArray[ElementType, SIZE]
    """The underlying storage for this array value."""

    # ===------------------------------------------------------------------===#
    # Constructors
    # ===------------------------------------------------------------------===#

    @always_inline
    fn __init__(inout self):
        """Constructs an empty (undefined) array."""

        self.storage = InlineArray[ElementType, SIZE]()

    # ===------------------------------------------------------------------=== #
    # Trait Interfaces
    # ===------------------------------------------------------------------=== #

    fn __len__(self) -> Int:
        """Returns the length of the array. This is a known constant value.

        Returns:
            The length of the array
        """
        return SIZE

    fn __setitem__(inout self, index: Int, owned value: ElementType):
        var ptr = __mlir_op.`pop.array.gep`(
            UnsafePointer(Reference(self.storage.array)).address, index.value
        )
        __mlir_op.`pop.store`(value, ptr)

    # ===------------------------------------------------------------------=== #
    # Methods
    # ===------------------------------------------------------------------=== #

    fn as_ptr(self) -> LegacyPointer[ElementType]:
        """Get a pointer to the elements contained by this array.

        Returns:
            A pointer to the elements contained by this array.
        """

        return LegacyPointer.address_of(self.storage).bitcast[ElementType]()
