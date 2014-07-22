//===--- NSSwiftArray.swift - Links NSArray and _ContiguousArrayStorage ---===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2015 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
//
//  _NSSwiftArray supplies the implementation of the _CocoaArrayType API
//  (and thus, NSArray the API) for our _ContiguousArrayStorage<T>.  We
//  can't put this implementation directly on _ContiguousArrayStorage
//  because generic classes can't override Objective-C selectors.
//
//===----------------------------------------------------------------------===//

import SwiftShims

// Base class of the heap buffer implementation backing the new Array
// design.  
@objc internal
class _NSSwiftArray : HeapBufferStorageBase, _CocoaArrayType {
  typealias Buffer = HeapBuffer<_ArrayBody, AnyObject>
  
  func canStoreElementsOfDynamicType(_: Any.Type) -> Bool {
    _fatalError(
      "Concrete subclasses must implement canStoreElementsOfDynamicType")
  }

  /// A type that every element in the array is.
  var staticElementType: Any.Type {
    _fatalError(
      "Concrete subclasses must implement staticElementType")
  }

  /// Returns the object located at the specified `index`.
  func objectAtIndex(index: Int) -> AnyObject {
    let buffer = reinterpretCast(self) as Buffer
    if _fastPath(buffer.value.elementTypeIsBridgedVerbatim) {
      return buffer[index]
    }
    return bridgingObjectAtIndex(index)
  }

  /// Copies the objects contained in the array that fall within the
  /// specified `range` to `aBuffer`.
  func getObjects(
    aBuffer: UnsafeMutablePointer<AnyObject>, range: _SwiftNSRange
  ) {
    let buffer = reinterpretCast(self) as Buffer
    
    if _fastPath(buffer.value.elementTypeIsBridgedVerbatim || count == 0) {
      // These objects are "returned" at +0, so treat them as values to
      // avoid retains.
      var dst = UnsafeMutablePointer<Word>(aBuffer)
      
      if _fastPath(buffer.value.elementTypeIsBridgedVerbatim) {
        dst.initializeFrom(
          UnsafeMutablePointer(buffer.elementStorage + range.location),
          count: range.length)
      }
      
      for i in range.location..<range.location + range.length {
        dst++.initialize(reinterpretCast(buffer[i]))
      }
    }
    else {
      bridgingGetObjects(aBuffer, range: range)
    }
  }

  func copyWithZone(_: COpaquePointer) -> _CocoaArrayType {
    return self
  }

  func countByEnumeratingWithState(
    state: UnsafeMutablePointer<_SwiftNSFastEnumerationState>,
    objects: UnsafeMutablePointer<AnyObject>, count bufferSize: Int
  ) -> Int {
    let buffer = reinterpretCast(self) as Buffer
    if _fastPath(buffer.value.elementTypeIsBridgedVerbatim) {
      var enumerationState = state.memory
      
      if enumerationState.state != 0 {
        return 0
      }
      enumerationState.mutationsPtr = _fastEnumerationStorageMutationsPtr
      enumerationState.itemsPtr = reinterpretCast(buffer.elementStorage)
      enumerationState.state = 1
      state.memory = enumerationState
      return buffer.value.count
    }
    else {
      return bridgingCountByEnumeratingWithState(
        state, objects: objects, count: bufferSize)
    }
  }
  
  var count: Int {
    return (reinterpretCast(self) as Buffer).value.count
  }

  //===--- Support for bridging arrays non-verbatim-bridged types ---------===//
  // The optional Void arguments prevent these methods from being
  // @objc, rendering them overridable by the generic class
  // _ContiguousArrayStorage<T>
  
  /// Returns the object located at the specified `index` when the
  /// element type is not bridged verbatim.  
  func bridgingObjectAtIndex(index: Int, _: Void = ()) -> AnyObject {
    _fatalError(
      "Concrete subclasses must implement bridgingObjectAtIndex")
  }

  /// Copies the objects contained in the array that fall within the
  /// specified range to `aBuffer`.
  func bridgingGetObjects(
    aBuffer: UnsafeMutablePointer<AnyObject>,
    range: _SwiftNSRange, _: Void = ()
  ) {
    _fatalError(
      "Concrete subclasses must implement bridgingGetObjects")
  }

  func bridgingCountByEnumeratingWithState(
    state: UnsafeMutablePointer<_SwiftNSFastEnumerationState>,
    objects: UnsafeMutablePointer<AnyObject>,
    count bufferSize: Int, _: Void = ()
  ) -> Int {
    _fatalError(
      "Concrete subclasses must implement bridgingCountByEnumeratingWithState")
  } 
}
