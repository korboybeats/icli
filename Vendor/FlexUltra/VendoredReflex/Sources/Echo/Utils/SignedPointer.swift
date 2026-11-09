//
//  SignedPointer.swift
//  Echo
//
//  Created by Alejandro Alonso
//  Copyright © 2021 Alejandro Alonso. All rights reserved.
//

import CEcho

// A wrapper around a pointer who will return the signed version of the wrapped
// pointer through the `signed` property.
struct SignedPointer<Pointee> {
  var ptr: UnsafeRawPointer!
  
  var signed: UnsafeRawPointer! {
    #if _ptrauth(_arm64e)
    if Pointee.self == ProtocolDescriptor.self ||
       Pointee.self == ValueWitnessTable.self ||
       Pointee.self is any TypeContextDescriptor.Type {
      return __ptrauth_strip_asda(ptr)
    }
    #endif
    return ptr
  }
}
