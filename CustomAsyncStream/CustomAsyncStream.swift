//
//  CustomAsyncStream.swift
//  CustomAsyncStream
//
//  Created by Saverio Negro on 4/10/26.
//

import SwiftUI

struct CustomAsyncStream<Element>: AsyncSequence {
    
    typealias Element = Element
    typealias AsyncIterator = Iterator
    
    let elementType: Element.Type
    let asyncStreamState: AsyncStreamState = AsyncStreamState()
    
    init(
        _ elementType: Element.Type = Element.self,
        build: @escaping (Continuation) -> Void
    ) {
        self.elementType = elementType
        
        let continuation = Continuation(self.asyncStreamState)
        build(continuation)
    }
    
    func makeAsyncIterator() -> Iterator {
        return Iterator(self.asyncStreamState)
    }
}

// `CustomAsyncStream`'s `Iterator`
extension CustomAsyncStream {
    
    struct Iterator: AsyncIteratorProtocol {
        
        typealias Element = CustomAsyncStream.Element
        typealias Failure = Never
        
        let asyncStreamState: AsyncStreamState
        
        init(_ asyncStreamState: AsyncStreamState) {
            self.asyncStreamState = asyncStreamState
        }
        
        func next() async -> CustomAsyncStream<Element>.Element? {
            return await self.pull()
        }
        
        // pull the next element in the buffer queue, or await on the
        // continuation to push new values into the stream.
        func pull() async -> Element? {
            return await self.asyncStreamState.pull()
        }
    }
}

// `CustomAsyncStream`'s `Continuation`

/**
   Acts as a public interface object for developers to perform insertion
   into the stream as well as termination of such a stream. Also, it references
   the actual continuation encapsulated in the async stream's state.
   It mimics Apple's `AsyncStream<Element>.Continuation` type and functions as
   a "Push" model for the async stream.
*/
extension CustomAsyncStream {
    
    struct Continuation {
        
        typealias YieldResult = CustomAsyncStream.Element
        
        let asyncStreamState: AsyncStreamState
        
        init(_ asyncStreamState: AsyncStreamState) {
            self.asyncStreamState = asyncStreamState
        }
        
        @discardableResult
        func yield(_ value: YieldResult) async -> YieldResult {
            await self.asyncStreamState.push(value)
            return value
        }
        
        func finish() async {
            await self.asyncStreamState.finish()
        }
    }
}

// `CustomAsyncStream`'s `AsyncStreamState`

/**
The state of the stream shared by both the `Continuation` type (Push model)
as well as the `Iterator` type (Pull model).
An instance of the `AsyncStreamState` actor is dependency-injected in the constructor
of both the `Continuation` as well as the `Iterator` types in order to be
able to refer to the same object in the Heap Memory.
*/
extension CustomAsyncStream {
    
    actor AsyncStreamState {
        
        typealias Element = CustomAsyncStream.Element
        
        var buffer: [CustomAsyncStream.Element] = []
        var isCompleted = false
        var continuation: CheckedContinuation<CustomAsyncStream.Element?, Never>? = nil
        
        func push(_ value: Element) {
            
            if let continuation = continuation {
                
                // If a continuation exists, it means the async stream is waiting for
                // the data source to push the next value.
                self.continuation = nil
                continuation.resume(returning: value)
            } else {
                
                // If no continuation is being held by the state, it means the
                // async stream is currently processing another element of the stream.
                // In order to avoid upcoming data to be lost, we store it into a buffer queue.
                buffer.append(value)
            }
        }
        
        func finish() {
            
            if self.continuation != nil {
                self.continuation?.resume(returning: nil)
            }
            
            self.isCompleted = true
        }
        
        func pull() async -> Element? {
            
            // If the buffer is not empty, the async stream is dequeueing values from it
            if !buffer.isEmpty {
                return buffer.removeFirst()
            } else if isCompleted {
                
                // If the buffer is empty and the stream was terminated by the `Continuation` public interface,
                // then finish the stream by returning `nil` to the `Iterator`
                return nil
            }
            
            // If the buffer is empty, and the stream is not terminated, then we need to await
            // on a continuation before pulling values into the stream
            return await withCheckedContinuation { (continuation: CheckedContinuation<CustomAsyncStream.Element?, Never>) in
                self.continuation = continuation
            }
        }
    }
}

