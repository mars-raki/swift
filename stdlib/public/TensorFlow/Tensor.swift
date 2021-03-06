//===-- Tensor.swift ------------------------------------------*- swift -*-===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
// This is the core Tensor abstraction, which is conceptually equivalent to a
// NumPy ndarray.  It carries no rank information in its static type, so it can
// be used by model developers who don't want it.
//
//===----------------------------------------------------------------------===//

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin
#else
import Glibc
#endif
import CTensorFlow

//===----------------------------------------------------------------------===//
// Tensor
//===----------------------------------------------------------------------===//

/// `Tensor` is a multi-dimensional array used for computation. It is a wrapper
/// around a `TensorHandle`.
@_fixed_layout
public struct Tensor<Scalar : AccelerableByTensorFlow> : TensorProtocol {
  /// The underlying `TensorHandle`.
  /// - Note: `handle` is public to allow user defined ops, but should not
  /// normally be used otherwise.
  public let handle: TensorHandle<Scalar>

  @_inlineable
  public init(handle: TensorHandle<Scalar>) {
    self.handle = handle
  }
}

//===----------------------------------------------------------------------===//
// Compiler intrinsics
//===----------------------------------------------------------------------===//
//
// By default, when a `Tensor` value is implicitly passed between host and
// tensor code, the partitioning pass will generate a warning. Users can
// indicate that they are doing something intentionally by using these methods,
// which silences the warning.
//
// TODO: These would be nicer defined as builtins rather than "well known
// functions".

@_versioned @inline(never)
@_silgen_name("__tf_send")
@effects(readnone)
func _TFSend<Scalar>(_ handle: TensorHandle<Scalar>) -> TensorHandle<Scalar> {
  return handle
}

@_versioned @inline(never)
@_silgen_name("__tf_receive")
func _TFReceive<Scalar>(_ handle: TensorHandle<Scalar>)
  -> TensorHandle<Scalar> {
  return handle
}

/// This function converts a `TensorHandle` that is known to have a 0-d value
/// into the scalar that it produces. This is intended for use in op definitions
/// where it is known that the op always returns a 0-d tensor. It is not for use
/// in general code.
@_versioned @_inlineable @inline(__always)
func _TFGetScalarOrDie<Scalar>(_ handle: TensorHandle<Scalar>) -> Scalar {
  return Scalar._getScalarOrDie(handle)
}

/// This function converts a `TensorHandle` into a scalar if it is 0-d, or
/// returns nil otherwise.
@_versioned @_inlineable @inline(__always)
func _TFGetScalar<Scalar>(_ handle: TensorHandle<Scalar>) -> Scalar? {
  return Scalar._getScalar(handle)
}

/// This compiler builtin is known by the partitioning pass, which recognizes it
/// and promotes calls to it to being in graph when it can. This signature was
/// designed to align with the requirements of the `Const` TensorFlow operation.
@_versioned @inline(never)
@_silgen_name("__tf_tensor_from_scalars")
func _TFTensorFromScalars<Scalar>(
  _ scalars: [Scalar], shape: [Int32]
) -> TensorHandle<Scalar> {
  let contiguousSize = shape.map(Int.init).reduce(1, *)
  precondition(scalars.count == contiguousSize,
               "The number of scalars does not match the shape.")
  return TensorHandle(
    shape: shape,
    scalarsInitializer: { addr in
      scalars.withUnsafeBufferPointer { ptr in
        addr.assign(from: ptr.baseAddress!, count: contiguousSize)
      }
    }
  )
}

@_versioned @_inlineable @inline(__always)
func _TFMakeScalarTensor<Scalar>(_ scalar: Scalar) -> TensorHandle<Scalar> {
  return Scalar._makeScalarTensor(scalar)
}

@_versioned @inline(never)
@_silgen_name("__tf_tensor_from_scalars_1d")
func _TFTensorFromScalars1D<Scalar>(_ scalars: [Scalar])
  -> TensorHandle<Scalar> {
  return _TFTensorFromScalars(scalars, shape: [Int32(scalars.count)])
}

@_versioned @_inlineable @inline(__always)
func _TFHoistable<Scalar>(_ fn: () -> TensorHandle<Scalar>)
  -> TensorHandle<Scalar> {
  return Scalar._hoistableClosure(fn)
}

//===----------------------------------------------------------------------===//
// Memory transfer markers
//===----------------------------------------------------------------------===//

/// TODO: Remove when send/receive semantics gets revisited.
public extension Tensor {
  /// Mark memory transfer to device.
  @_inlineable @inline(__always)
  func toDevice() -> Tensor {
    return Tensor(handle: _TFSend(handle))
  }

  /// Mark memory transfer to host.
  @_inlineable @inline(__always)
  func toHost() -> Tensor {
    return Tensor(handle: _TFReceive(handle))
  }
}

//===----------------------------------------------------------------------===//
// Initialization
//===----------------------------------------------------------------------===//

public extension Tensor where Scalar : Numeric {
  /// Perform an element-wise conversion from another `Tensor`.
  @_inlineable @inline(__always)
  init<OtherScalar : Numeric>(_ other: Tensor<OtherScalar>) {
    self = Raw.cast(other)
  }
}

public extension Tensor {
  /// Creates a tensor from a scalar value.
  @_inlineable @inline(__always)
  init(_ value: Scalar) {
    self.init(handle: _TFMakeScalarTensor(value))
  }

  /// Creates a tensor from an array of tensors (which may themselves be
  /// scalars).
  @_inlineable @inline(__always)
  init(_ elements: [Tensor]) {
    self = Raw.pack(values: elements)
  }

  /// Creates a 1D tensor in from contiguous scalars in row-major order.
  ///
  /// - Parameters:
  ///   - vector: The scalar contents of the tensor.
  /// - Precondition: The number of scalars must equal the product of the
  ///   dimensions of the shape.
  ///
  @_inlineable @inline(__always)
  init(_ vector: [Scalar]) {
    self.init(handle: _TFTensorFromScalars1D(vector))
  }

  /// Creates a 1D tensor in from contiguous scalars in row-major order.
  ///
  /// - Parameters:
  ///   - vector: The scalar contents of the tensor.
  /// - Precondition: The number of scalars must equal the product of the
  ///   dimensions of the shape.
  ///
  @_inlineable @inline(__always)
  init<C : RandomAccessCollection>(_ vector: C) where C.Element == Scalar {
    let handle = _TFHoistable {
      TensorHandle<Scalar>(
        shape: [Int32(vector.count)],
        scalarsInitializer: { addr in
          var currentAddr = addr
          for scalar in vector {
            currentAddr.initialize(to: scalar)
            currentAddr = currentAddr.advanced(by: 1)
          }
        }
      )
    }
    self.init(handle: handle)
  }

  /// Creates a tensor with the specified shape and contiguous scalars in
  /// row-major order.
  ///
  /// - Parameters:
  ///   - shape: The shape of the tensor.
  ///   - scalars: The scalar contents of the tensor.
  /// - Precondition: The number of scalars must equal the product of the
  ///   dimensions of the shape.
  ///
  @_inlineable @inline(__always)
  init(shape: TensorShape, scalars: [Scalar]) {
    // NOTE: We use `_TFTensorFromScalars` here so the compiler can try to
    // promote constants and avoid copies.
    self.init(handle: _TFTensorFromScalars(scalars, shape: shape.dimensions))
  }

  /// Creates a tensor with the specified shape and contiguous scalars in
  /// row-major order.
  ///
  /// - Parameters:
  ///   - shape: The shape of the tensor.
  ///   - scalars: The scalar contents of the tensor.
  /// - Precondition: The number of scalars must equal the product of the
  ///   dimensions of the shape.
  ///
  @_inlineable @inline(__always)
  init(shape: TensorShape, scalars: UnsafeBufferPointer<Scalar>) {
    let handle: TensorHandle<Scalar> = _TFHoistable {
      precondition(scalars.count == shape.contiguousSize)
      return TensorHandle<Scalar>(
        shape: shape.dimensions,
        scalarsInitializer: { addr in
          addr.initialize(from: scalars.baseAddress!,
                          count: Int(shape.contiguousSize))
        }
      )
    }
    self.init(handle: handle)
  }

  /// Creates a tensor with the specified shape and contiguous scalars in
  /// row-major order.
  ///
  /// - Parameters:
  ///   - shape: The shape of the tensor.
  ///   - scalars: The scalar contents of the tensor.
  /// - Precondition: The number of scalars must equal the product of the
  ///   dimensions of the shape.
  ///
  @_inlineable @inline(__always)
  init<C : RandomAccessCollection>(shape: TensorShape, scalars: C)
    where C.Element == Scalar {
    let handle: TensorHandle<Scalar> = _TFHoistable {
      precondition(scalars.count == shape.contiguousSize)
      return TensorHandle<Scalar>(
        shape: shape.dimensions,
        scalarsInitializer: { addr in
          var currentAddr = addr
          for scalar in scalars {
            currentAddr.initialize(to: scalar)
            currentAddr = currentAddr.advanced(by: 1)
          }
        }
      )
    }
    self.init(handle: handle)
  }

  /// Creates a tensor with the specified shape and a single, repeated value.
  ///
  /// - Parameters:
  ///   - shape: The dimensions of the tensor.
  ///   - repeatedValue: The scalar value to repeat.
  ///
  @_inlineable @inline(__always)
  init(shape: TensorShape, repeating repeatedValue: Scalar) {
    self = Raw.fill(
      dims: Tensor<Int32>(shape.dimensions), value: Tensor(repeatedValue))
  }

  /// Creates a tensor by broadcasting the given scalar to a given rank with
  /// all dimensions being 1.
  @_inlineable @inline(__always)
  init(broadcasting scalar: Scalar, rank: Int32) {
    let shapeTensor = Tensor<Int32>(shape: [rank], repeating: 1)
    self = Raw.fill(dims: shapeTensor, value: Tensor(scalar))
  }

  /// Creates a tensor of shape `[4]` from a 4-tuple.
  /// - Note: This is intended for internal use, for example, to initialize a
  ///   tensor attribute from `convolved2D`'s `strides` argument.
  @_versioned @_inlineable @inline(__always)
  internal init(_ scalars: (Scalar, Scalar, Scalar, Scalar)) {
    self.init([scalars.0, scalars.1, scalars.2, scalars.3])
  }
}

//===----------------------------------------------------------------------===//
// Initialization syntax
//===----------------------------------------------------------------------===//

// Background story on `TensorElementLiteral` and why it's necessary:
//
// Very importantly, we want users to be able to implicitly convert an array
// literal to a tensor. At a first glance, a straightfoward implementation would
// be conforming `Tensor` to `ExpressibleByArrayLiteral` with
// `ExpressibleBy(Float|Int|Bool)Literal` as a base case. However, it is not
// that simple. We have binary operators that take `(Tensor, Scalar)`, `(Scalar,
// Tensor)` as well as `(Tensor, Tensor)`. When `Tensor` are convertible from
// both a scalar and an array literal, a scalar-tensor binary operator like `+`
// will not type check.
//
// One way to word around is to define all tensor-tensor operators on a
// protocol extension, and all tensor-scalar and scalar-tensor operators on
// concrete `Tensor`. Protocol extensions are less favorable than concrete
// implementations, so the compiler will prefer the concrete implementation for
// a scalar-tensor operation. However, this would cause enormous code bloat and
// is entirely a hack.
//
// To resolve ambiguity, `Tensor` should not be expressible by scalar literal.
// There's already a lightweight syntax for converting a scalar to a tensor:
// `Tensor(x)`, so there is no strong need for implicit conversion. But we need
// to find a way to give `ExpressibleByArrayLiteral` a base case: what would the
// `ArrayLiteralElement` be if we want to support both `[1,2,3]` and `[[[1,2],
// [1,2]]]`? In the first case the array literal element is an interger, while
// in the second case the array literal itself should be a tensor. Based on this
// observation, we can come up with an intermediate type: `TensorLiteralElement`
// as the `ArrayLiteralElement` of `Tensor`. By making `TensorLiteralElement`
// expressible by both array literal and scalar literal, `Tensor` can now be
// converted from an arbitrary-dimensional array literal.
//
// Due to protocol requirements, `TensorElementLiteral` has to be
// public. It is never supposed to be used directly by any user, so the library
// convention is to prepend an underscore to its name, making it
// `_TensorElementLiteral`. However, we chose not to do that because underscored
// types are ugly in error messages involving literal conversions to tensors.
//
// It would be nice to be able to remove this type when we can systematically
// resolve tensor-scalar/scalar-tensor op ambiguity someday, either through an
// improved `Expressible` model, or by introducing an attribute to tell the type
// checker which function to prefer when ambiguity occurs.

/// Represents a literal element for conversion to a `Tensor`.
///
/// - NOTE: Do not use this API directly. This is implicitly created during the
/// conversion from an array literal to a `Tensor`.
@_fixed_layout
public struct TensorElementLiteral<Scalar> : TensorProtocol
  where Scalar : AccelerableByTensorFlow {

  @_versioned let tensor: Tensor<Scalar>

  @_inlineable
  public var handle: TensorHandle<Scalar> {
    return tensor.handle
  }

  @_inlineable
  public init(handle: TensorHandle<Scalar>) {
    tensor = Tensor(handle: handle)
  }
}

extension TensorElementLiteral : ExpressibleByBooleanLiteral
  where Scalar : ExpressibleByBooleanLiteral {
  public typealias BooleanLiteralType = Scalar.BooleanLiteralType
  @_inlineable @inline(__always)
  public init(booleanLiteral: BooleanLiteralType) {
    tensor = Tensor(Scalar(booleanLiteral: booleanLiteral))
  }
}

extension TensorElementLiteral : ExpressibleByIntegerLiteral
  where Scalar : ExpressibleByIntegerLiteral {
  public typealias IntegerLiteralType = Scalar.IntegerLiteralType
  @_inlineable @inline(__always)
  public init(integerLiteral: IntegerLiteralType) {
    tensor = Tensor(Scalar(integerLiteral: integerLiteral))
  }
}

extension TensorElementLiteral : ExpressibleByFloatLiteral
  where Scalar : ExpressibleByFloatLiteral {
  public typealias FloatLiteralType = Scalar.FloatLiteralType
  @_inlineable @inline(__always)
  public init(floatLiteral: FloatLiteralType) {
    tensor = Tensor(Scalar(floatLiteral: floatLiteral))
  }
}

extension TensorElementLiteral : ExpressibleByArrayLiteral {
  public typealias ArrayLiteralElement = TensorElementLiteral<Scalar>
  @_inlineable @inline(__always)
  public init(arrayLiteral elements: TensorElementLiteral<Scalar>...) {
    tensor = #tfop("Pack", elements)
  }
}

extension Tensor : ExpressibleByArrayLiteral {
  /// The type of the elements of an array literal.
  public typealias ArrayLiteralElement = TensorElementLiteral<Scalar>

  /// Creates a tensor initialized with the given elements.
  /// - Note: This is for conversion from tensor element literals. This is a
  /// separate method because `ShapedArray` initializers need to call it.
  @_versioned @_inlineable @inline(__always)
  internal init(
    tensorElementLiterals elements: [TensorElementLiteral<Scalar>]
  ) {
    self.init(handle: #tfop("Pack", elements))
  }

  /// Creates a tensor initialized with the given elements.
  @_inlineable @inline(__always)
  public init(arrayLiteral elements: TensorElementLiteral<Scalar>...) {
    self.init(tensorElementLiterals: elements)
  }
}

//===----------------------------------------------------------------------===//
// Properties
//===----------------------------------------------------------------------===//

public extension Tensor {
  /// The number of dimensions of the `Tensor`.
  @_inlineable
  var rank: Int32 {
    @inline(__always)
    get {
      return _TFGetScalarOrDie(rankTensor.handle)
    }
  }

  /// The dimensions of the `Tensor`.
  @_inlineable
  var shape: TensorShape {
    @inline(__always)
    get {
      return TensorShape(shapeTensor.scalars)
    }
  }

  /// The number of scalars in the `Tensor`.
  @_inlineable
  var scalarCount: Int32 {
    @inline(__always)
    get {
      return _TFGetScalarOrDie(scalarCountTensor.handle)
    }
  }
}

//===----------------------------------------------------------------------===//
// Numeric initialization
//===----------------------------------------------------------------------===//

public extension Tensor where Scalar : Numeric {
  /// Creates a tensor with all scalars set to zero.
  ///
  /// - Parameter shape: The dimensions of the tensor.
  @_inlineable @inline(__always)
  init(zeros shape: TensorShape) {
    self.init(shape: shape, repeating: 0)
  }

  /// Creates a tensor with all scalars set to one.
  ///
  /// - Parameter shape: The dimensions of the tensor.
  @_inlineable @inline(__always)
  init(ones shape: TensorShape) {
    self.init(shape: shape, repeating: 1)
  }

  @inline(never) // make @_inlineable when implemented.
  static func eye(
    rowCount: Int, columnCount: Int? = nil, batchShape: [Int]? = nil
  ) -> Tensor {
    // NOTE: TF doesn't have an "Eye" op. Instead, the `tf.eye` function
    // composes many tensor/linear algebra ops.
    fatalError("FIXME: implement eye")
  }

  /// Creates a 1-D tensor representing a sequence from a starting value to, but
  /// not including, an end value, stepping by the specified amount.
  ///
  /// - Parameters:
  ///   - start: The starting value to use for the sequence. If the sequence
  ///     contains any values, the first one is `start`.
  ///   - end: An end value to limit the sequence. `end` is never an element of
  ///     the resulting sequence.
  ///   - stride: The amount to step by with each iteration. `stride` must be
  ///     positive.
  ///
  @_inlineable @inline(__always)
  init(rangeFrom start: Scalar, to end: Scalar, stride: Scalar) {
    self = Raw.range(
      start: Tensor(start),
      limit: Tensor(end),
      delta: Tensor(stride))
  }

  /// Creates a one-hot tensor at given indices. The locations represented by
  /// `indices` take value `onValue` (`1` by default), while all other locations
  /// take value `offValue` (`0` by default). If the input `indices` is rank
  /// `n`, the new tensor will have rank `n+1`. The new axis is created at
  /// dimension `axis` (by default, the new axis is appended at the end).
  ///
  /// If `indices` is a scalar, the new tensor's shape will be a vector of
  /// length `depth`.
  ///
  /// If `indices` is a vector of length `features`, the output shape will be:
  ///     features x depth, if axis == -1
  ///     depth x features, if axis == 0
  ///
  /// If `indices` is a matrix (batch) with shape `[batch, features]`, the
  /// output shape will be:
  ///     batch x features x depth, if axis == -1
  ///     batch x depth x features, if axis == 1
  ///     depth x batch x features, if axis == 0
  ///
  /// - Parameters:
  ///   - indices: A `Tensor` of indices.
  ///   - depth: A scalar defining the depth of the one hot dimension.
  ///   - onValue: A scalar defining the value at the location referred to by
  ///     some index in `indices`.
  ///   - offValue: A scalar defining the value at a location that is not
  ///     referred to by any index in `indices`.
  ///   - axis: The axis to fill. The default is `-1`, a new inner-most axis.
  ///
  @_inlineable @inline(__always)
  init(oneHotAtIndices indices: Tensor<Int32>, depth: Int32,
       onValue: Scalar = 1, offValue: Scalar = 0, axis: Int = -1) {
    self = Raw.oneHot(
      indices: indices,
      depth: Tensor<Int32>(depth),
      onValue: Tensor(onValue),
      offValue: Tensor(offValue),
      axis: Int64(axis)
    )
  }
}

//===----------------------------------------------------------------------===//
// Random initialization
//===----------------------------------------------------------------------===//

public extension Float {
  /// Produces a random value from the standard uniform distribution.
  /// - Parameter state: An optional `RandomState` instance. If `nil`,
  ///   `RandomState.global` will be used.
  static func randomUniform(state: RandomState? = nil) -> Float {
    let state = state ?? RandomState.global
    return Float(state.generate()) / Float(RAND_MAX)
  }

  private static var boxMullerHelper: Float = randomUniform()

  /// Produces a random value from a normal distribution using the Box-Muller
  /// method.
  ///
  /// - Parameters:
  ///   - mean: The mean of the normal distribution.
  ///   - stddev: The standard deviation of the normal distribution.
  ///   - state: An optional `RandomState` instance. If `nil`,
  ///     `RandomState.global` will be used.
  static func randomNormal(mean: Float = 0, stddev: Float = 1,
                           state: RandomState? = nil) -> Float {
    let tmp = randomUniform(state: state)
    let result = sqrtf(-2 * logf(tmp)) * cosf(2 * .pi * boxMullerHelper)
    boxMullerHelper = result
    return result * stddev + mean
  }
}

public extension Double {
  /// Produces a random value from the standard uniform distribution.
  /// - Parameter state: An optional `RandomState` instance. If `nil`,
  ///   `RandomState.global` will be used.
  static func randomUniform(state: RandomState? = nil) -> Double {
    let state = state ?? RandomState.global
    return Double(state.generate()) / Double(RAND_MAX)
  }

  private static var boxMullerHelper: Double = randomUniform()

  /// Produces a random value from a normal distribution using the Box-Muller
  /// method.
  ///
  /// - Parameters:
  ///   - mean: The mean of the normal distribution.
  ///   - stddev: The standard deviation of the normal distribution.
  ///   - state: An optional `RandomState` instance. If `nil`,
  ///     `RandomState.global` will be used.
  static func randomNormal(mean: Double = 0, stddev: Double = 1,
                           state: RandomState? = nil) -> Double {
    let tmp = randomUniform(state: state)
    let result = sqrt(-2 * log(tmp)) * cos(2 * .pi * boxMullerHelper)
    boxMullerHelper = result
    return result * stddev + mean
  }
}

public extension Tensor where Scalar == Int32 {
  /// Creates a tensor with the specified shape, randomly sampling scalar values
  /// from a discrete uniform distribution.
  ///
  /// - Parameters:
  ///   - shape: The dimensions of the tensor.
  ///   - state: The pseudorandom state in which the random numbers are being
  ///     generated.
  ///
  @_inlineable @inline(__always)
  init(randomStandardUniform shape: TensorShape, state: RandomState? = nil) {
    self = Tensor(
      handle: _TFHoistable {
        let state = state ?? RandomState.global
        return _TFTensorFromScalars(state.generate(Int(shape.contiguousSize)),
                                    shape: shape.dimensions)
      }
    ).toDevice()
  }
}

public extension Tensor where Scalar : BinaryFloatingPoint {
  /// Creates a tensor with the specified shape, randomly sampling scalar values
  /// from a uniform distribution between 0 and 1.
  ///
  /// - Parameters:
  ///   - shape: The dimensions of the tensor.
  ///   - state: The pseudorandom state in which the random numbers are being
  ///     generated.
  ///
  @_inlineable @inline(__always)
  init(randomUniform shape: TensorShape, state: RandomState? = nil) {
    self = Tensor(
      Tensor<Int32>(randomStandardUniform: shape, state: state)
    ) / Scalar(RAND_MAX)
  }

  /// Creates a tensor with the specified shape, randomly sampling scalar values
  /// from a normal distribution.
  ///
  /// - Parameters:
  ///   - shape: The dimensions of the tensor.
  ///   - mean: The mean of the distribution.
  ///   - stddev: The standard deviation of the distribution.
  ///   - state: The pseudorandom state in which the random numbers are being
  ///     generated.
  ///
  @_inlineable @inline(__always)
  init(randomNormal shape: TensorShape, mean: Scalar = 0, stddev: Scalar = 1,
       state: RandomState? = nil) {
    let uniform = Tensor(randomUniform: shape, state: state)
    let boxMullerHelper = Tensor(randomUniform: shape, state: state)
    let result = sqrt(-2 * log(uniform)) * cos(2 * .pi * boxMullerHelper)
    self = result * stddev + mean
  }
}

//===----------------------------------------------------------------------===//
// Shape transformations
//===----------------------------------------------------------------------===//

public extension AccelerableByTensorFlow {
  /// Convert to a tensor with the specified rank, with all dimensions equal to
  /// 1.
  @_inlineable @inline(__always)
  func makeTensor(withRank rank: Int32) -> Tensor<Self> {
    return Raw.fill(
      dims: Tensor<Int32>(ones: TensorShape(rank)),
      value: Tensor(self))
  }
}

public extension Tensor {
  /// Reshape to the shape of the specified `Tensor`.
  /// - Precondition: The number of scalars matches the new shape.
  @_inlineable @inline(__always)
  func reshaped<T>(like other: Tensor<T>) -> Tensor {
    return reshaped(toShape: other.shapeTensor)
  }

  /// Reshape to the specified shape.
  /// - Precondition: The number of scalars matches the new shape.
  @_inlineable @inline(__always)
  func reshaped(to newShape: TensorShape) -> Tensor {
    return reshaped(toShape: Tensor<Int32>(newShape.dimensions))
  }

  /// Reshape to the specified `Tensor` representing a shape.
  /// - Precondition: The number of scalars matches the new shape.
  @_inlineable @inline(__always)
  @differentiable(
    reverse, withRespectTo: (self),
    adjoint: _adjointReshaped(toShape:originalValue:seed:)
  )
  func reshaped(toShape newShape: Tensor<Int32>) -> Tensor {
    return Raw.reshape(self, shape: newShape)
  }

  /// Return a copy of the tensor collapsed into a 1-D `Tensor`, in row-major
  /// order.
  @_inlineable @inline(__always)
  func flattened() -> Tensor {
    return reshaped(to: [-1])
  }

  /// Returns a rank-lifted `Tensor` with a leading dimension of 1.
  @_inlineable @inline(__always)
  func rankLifted() -> Tensor {
    return expandingShape(at: 0)
  }

  /// Returns a shape-expanded `Tensor`, with a dimension of 1 inserted at the
  /// specified shape index.
  @_inlineable @inline(__always)
  @differentiable(
    reverse, withRespectTo: (self),
    adjoint: _adjointExpandingShape(at:originalValue:seed:)
  )
  func expandingShape(at shapeIndex: Int32) -> Tensor {
    return Raw.expandDims(self, dim: Tensor<Int32>(shapeIndex))
  }

  /// Remove the specified dimensions of size 1 from the shape of a tensor. If
  /// no dimensions are specified, then all dimensions of size 1 will be
  /// removed.
  // FIXME: The gradient for variadic `squeezed` is difficult to express because
  // ExpandDims only expands one axis at a time.
  @_inlineable @inline(__always)
  func squeezingShape(at axes: Int32...) -> Tensor {
    return Raw.squeeze(self, squeezeDims: axes)
  }

  /// Reshape to scalar.
  /// - Precondition: The tensor has exactly one scalar.
  @_inlineable
  func scalarized() -> Scalar {
    return _TFGetScalarOrDie(reshaped(to: []).handle)
  }
}

//===----------------------------------------------------------------------===//
// Scalar conversion
//===----------------------------------------------------------------------===//

public extension Tensor {
  /// Returns `true` if `rank` is equal to 0 and `false` otherwise.
  @_inlineable
  var isScalar: Bool {
    @inline(__always)
    get {
      return rank == 0
    }
  }

  /// Returns the single scalar element if `rank` is equal to 0 and `nil`
  /// otherwise.
  @_inlineable
  var scalar: Scalar? {
    @inline(__always)
    get {
      return Scalar(self)
    }
  }
}

public extension AccelerableByTensorFlow {
  @_inlineable @inline(__always)
  init?(_ tensor: Tensor<Self>) {
    guard let scalar = _TFGetScalar(tensor.handle) else {
      return nil
    }
    self = scalar
  }
}

//===----------------------------------------------------------------------===//
// Equality
//===----------------------------------------------------------------------===//

extension Tensor : Equatable where Scalar : Equatable {
  @_inlineable @inline(__always)
  public static func == (lhs: Tensor, rhs: Tensor) -> Bool {
    return lhs.elementsEqual(rhs).all()
  }

  @_inlineable @inline(__always)
  public static func != (lhs: Tensor, rhs: Tensor) -> Bool {
    return lhs.elementsNotEqual(rhs).any()
  }
}

//===----------------------------------------------------------------------===//
// Description and visualization
//===----------------------------------------------------------------------===//

/// String conversion.
extension Tensor : CustomStringConvertible {
  public var description: String {
    return array.description
  }
}

/// Xcode Playground display conversion.
extension Tensor : CustomPlaygroundDisplayConvertible {
  public var playgroundDescription: Any {
    return description
  }
}

/// Mirror representation, used by debugger/REPL.
extension Tensor : CustomReflectable {
  public var customMirror: Mirror {
    return Mirror(self, children: [], displayStyle: .struct)
  }
}

//===----------------------------------------------------------------------===//
// Array conversion
//===----------------------------------------------------------------------===//

public extension Tensor {
  @_inlineable
  var array: ShapedArray<Scalar> {
    @inline(__always)
    get {
      debugLog("Returning a host copy of array.")
      // This is considered to be a well known way to produce a copy to the
      // host, so an "implicit copy to host" warning should not be produced.
      return toHost().handle.makeHostCopy()
    }
  }

  @_inlineable
  var scalars: [Scalar] {
    return array.scalars
  }
}
