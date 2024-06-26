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
# RUN: %mojo %s

from testing import assert_equal


def raise_an_error():
    raise Error("MojoError: This is an error!")


def main():
    try:
        _ = raise_an_error()
    except e:
        assert_equal(str(e), "MojoError: This is an error!")

    var myString: String = "FOO"
    var error = Error(myString)
    assert_equal(error, "FOO")
