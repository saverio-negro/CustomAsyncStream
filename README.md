# `CustomAsyncStream`

```swift
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
        
        // - TODO: Implement a `pull` method for the iterator to either
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
```

## Introduction

`CustomAsyncSequence` is an API that's meant to mimic Apple's native `AsyncStream`.

Apple's `AsyncStream` is a powerful API that comes from Apple's Concurrency Library,
and it's meant to provide developers with an object called a `Continuation` that serves
as an interface between synchronous (mainly) and asynchronous code.
However, the `Continuation` object plays an essential role as a public interface for
developers when it comes to an asynchronous stream. That's mainly because an async
stream is designed to work using a "Pull" model, requesting for/awaiting on data
asynchronously.

Now, this data that needs to be pushed into the stream is usually coming from
a data source known by the developer. On this note, Apple provides us
with a `Continuation` object, associated with the async stream, that 
acts as a "Push" model, allowing developers themselves to take full control and
decide when to push data coming from the data source, and when to
end the stream.

Under the hood, the "Pull" model part of the asynchronous stream is taken on by
the functionality it implements because of it being an `AsyncSequence` type.

If you have ever implemented an asynchronous sequence yourself, you should know
that all it tries to abstract is an ordered collection of elements that can
be iterated over _asynchronously_, which means that you are only going to ever
be able to access the next element of the sequence whenever it is available, since
such elements are supposed to be pushed into the stream over time, and the sequence
is designed so that you can sequentially await on them using a `for-await-in` loop.

Apple's `AsyncStream` conforms to the `AsyncSequence` protocol, and provides the required
implementations in a way that developers are provided with full control over
the state of the async stream; in that, they can manage the pushing of data 
coming over time, as well as ending the sequence. All being possible via an
object, of type `AsyncStream.Continuation` attached to the async stream's state, 
which they expose to developers — a special type of continuation that is designed 
to work with `AsyncStream`.

I would like to be clear that, in this documentation and all others I have for my
series on Frameworks, I try to _mimic_ how Apple has managed to engineer some of their
own frameworks. Therefore, even though the conceptual idea might be similar, in no way
my creations should be intended to claim that this is definitely the way Apple has
programmed such APIs; instead, this is meant to be treated as an appreciation,
and understanding of how Apple _might_ have come up with such functionalities, even by
using different tools and ideas, from a perspective of a Software Engineer who is
passionate about Apple's Ecosystem.

With this out of the way, let's look at my custom implementation of the async stream,
which I called `CustomAsyncStream`.

## Briefly on Creating the `CustomAsyncStream` Type using the `AsyncSequence` Protocol

Since the `AsyncStream` is an `AsyncSequence`, I had my `CustomAsyncStream` conform to the `AsyncSequence` protocol.
Remember that, when we have a type conform to `AsyncSequence`, the protocol requires that the conforming type implement 
two types — the associated types of that `AsyncSequence` protocol; namely, the `AsyncIterator` type, which is the meat of 
our asynchronous sequence, `CustomAsyncStream`, and the values to be awaiting on, `Element`.

In such a scenario, since we are building an asynchronous wrapper around a Combine's Publisher, we want to make sure that 
the type of Element's being yielded from the asynchronous stream are the ones emitted from our wrapped publisher; namely, 
the values of type `Publisher.Output`.
Look at the Iterator, or better yet, any type conforming to the `AsyncIteratorProtocol` as the actual engine that produces 
elements over time, and asynchronously dispatch them to the asynchronous sequence when they are ready.
In our specific case, we can tap into the functionality that provides the next element to be produces in the sequence 
when it's ready. Such a functionality can be found in the `next()` method, which is the one required by the 
`AsyncIteratorProtocol`, which is `async` and returns the `Element` type required by the `AsyncIteratorProtocol` itself.

That gives us the possibility to use an async for loop, `for await Element in AsyncSequence`, to await elements 
from the async iterator; specifically, every time the async for loop runs, it calls our implemented async `next()` method, 
which might suspend/await until the next value is ready, depending on whether or not there's
a continuation to be await on in the state of the async stream, `AsyncStreamState`,
which is an important piece of this architecture, and deserves to be covered in its own chapter.

## The `Iterator` Nested Struct: Concrete Type Implementation of `AsyncIteratorProtocol`

The following is the implementation of our `Iterator` struct defined nested within `CustomAsyncStream`:

```swift
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
        
        // Implement a `pull` method for the iterator to either
        // pull the next element in the buffer queue, or await on the
        // continuation to push new values into the stream.
        // The iterator taps into the state of the stream to
        // perform such an operation.
        func pull() async -> Element? {
            return await self.asyncStreamState.pull()
        }
    }
}
```

Every concrete implementation of `AsyncIteratorProtocol` is required to specify a type for the next element
to await on and pull from the stream — this element is typically coming from a data source known by the
developer; however, in the async stream API, the `Continuation` object is the one that is directly interfacing
with the asynchronous data source, while the iterator's job is to asynchronously request data from the state
of the stream — which is shared by both the `Continuation` and the `Iterator` — either via awaiting on
such a `Continuation` object to push values into the stream, or directly pulling it from a buffer queue
held by the state of the stream.

In fact, notice how the `Iterator` object taps into the state of the stream to `pull()` the next element.
Having a shared stream state (`AsyncStreamState`) with the `Continuation` allows this Push-and-Pull mechanism
to work.

The async `pull()` method is then used into the `next()` method, which is called for each running of the
for-await-in loop, providing the next element in the async sequence.

## The `Continuation` Nested Struct: The Public Bridging Interface to Async State's `CheckedContinuation`

The `Continuation` type acts as an abstraction for the actual `CheckedContinuation` encapsulated into the
state of the stream `AsyncStreamState`, and a public interfaces for developers to allow them to control
the stream as far as when to push values it, and when to terminate the stream.

It tries to mimic Apple's `AsyncStream<Element>.Continuation` type, and it's a crucial part of the API
since it carries out the "Push" mechanism needed for the async stream to work, while providing a public
interface to define rules for either pushing values into the stream, or terminating it.

The following is the implementation of our `Continuation` struct as part of the `CustomAsyncStream`:

```swift

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
```

Notice how the `Continuation` type refers to the state of the stream to perform either the `yield(_:)` method,
as well as the finish method. As we mentioned, the `Continuation` object acts just a public interface, and reverts
to the state of the stream — the instance of `AsyncStreamState`, which both the `Continuation` and `Iterator`
received as an external dependency via their constructors — which works with the actual `CheckedContinuation`
object as the core mechanism of the "Push-and-Pull" model for the API.

Also, before we look at how I went through the actual implementation of the `AsyncStreamState` actor, it's
important to notice how we are offering up such a `Continuation` object to developers to tap into and
ultimately control when to push values into the stream from an external data source.

```swift
struct CustomAsyncStream<Element>: AsyncSequence {
    
    ...
    
    let asyncStreamState: AsyncStreamState = AsyncStreamState()
    
    init(
        _ elementType: Element.Type = Element.self,
        build: @escaping (Continuation) -> Void
    ) {
        self.elementType = elementType
        
        let continuation = Continuation(self.asyncStreamState)
        build(continuation)
    }
```

Much like Apple's `AsyncStream` API, we are allowing users of `CustomAsyncStream` to access the `Continuation`
interface object as a parameter to the function of type `@escaping (Continuation) -> Void`, which we can pass
as a closure to the initializer's `build` parameter.

Within this closure, the user can then tap into the `Continuation` object as its parameter and be allowed indirect
interaction with the state of the stream (`AsyncStreamState`), while controlling the pushing of values from any
external data source.

Also, notice that, in the initializer of our `CustomAsyncStream` struct, we are injecting the reference to
the `AsyncStreamState` object stored as a property, `asyncStreamState`, onto our async stream. This allows the
continuation object to communicate with the async iterator, while acting as an interface for the stream.

## The `AsyncStreamState` Nested Actor: The Object Representing the State of the Stream

Finally, the last piece of the puzzle is the object that keeps track of the state of the stream, holding
information regarding the buffered data coming from the async data source, the completion state of the
stream, as well as the actual continuation of type `CheckedContinuation<CustomAsyncStream.Element?, Never>?`,
which lets the `AsyncIterator`, our "pull" model, _await_ on the next element from the data source which pushes
data over time through the `Continuation` object, our public interface.

The following is the implementation of our `AsyncStreamState` actor:

```swift

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
```

As you may notice, the `AsyncStreamState` actor defines the core implementations of the `push(_:)` and `finish()` 
methods, which are referenced by the `Continuation` object, and the `pull()` method, which is referenced 
by our `Iterator` object.

Let's briefly go over each of them:

- `push(:_)`: It pushes an `Element` into the stream from the data source interfacing the `Continuation` object.
   If a `CheckedContinuation<CustomAsyncStream.Element?, Never>?` exists, it means that the iterator is awaiting
   on the continuation to pull the next element into the stream. Upon the `Continuation` interface pushing
   a value in, the continuation is resumed, returning such a value of type `Element`.
   In case the continuation is `nil` in the state of the stream, it means that the iterator is already dealing
   with a value from the data source; in such an instance, to avoid losing data being pushed in from the data
   source while the iterator is busy, the method enqueues such value into the state's buffer queue, which will
   later be dequeued from the iterator at its due time.
   
- `finish()`: Terminates the asynchronous stream. If a continuation exists in the `AsyncStreamState` shared instance,
   it means that the iterator was awaiting on the next value to be push into the stream. However, when the stream
   is being terminated, the iterator doesn't need to await on anything; hence, the method resumes the
   continuation by returning `nil`, indicating that the stream is completed.
   
- `pull()`: Invoked by the `Iterator` object to pull the next value from the stream. It first checks the buffer for
   any value to dequeue; at which point, if a value exists, it dequeues it; otherwise, it first checks whether
   the stream is completed, and returns `nil` to terminate the for-await-in loop. However, if the buffer is empty,
   and the stream isn't yet finished, then the iterator should be awaiting for the `Continuation` object to
   push the next value in from the data source. In such an instance, we create a `CheckedContinuation` object
   to be stored into the shared `AsyncStreamState` instance, and to be resolved only after the pushing of a new
   value into the stream. You may appreciate how important the `AsyncStreamState` is when it comes to
   communication between the "Pull" model, represented by the `Iterator`, and the "Push" model, taken on
   by the `Continuation` object.
   
## Usage Example of `CustomAsyncStream`

The following is a dummy example that uses my `CustomAsyncStream` API to await on
`User?` data from the async stream over time.

Notice how the `DataManager` wraps our `userSubject` publisher responsible for
sending our user data to any subscriber — our `ContentViewModel`, in our case —
over time using a fake service, `MockUserService`, and acting as our source of
truth from which the async stream is going to pull data.

Also, notice how we handle the view model's subscription within its constructor
using a `CustomAsyncStream`, which allows the developer to control when to push
value into the stream, or when to finish the stream, thanks to our `continuation`
parameter of type `Continuation`, similar to how Apple lets us handle this dynamic
with its own `Continuation` object passed into thier `AsyncStream`'s initializer.

```swift
import SwiftUI
import Combine

// === Model ===

struct User: Codable, Hashable {
    let firstName: String
    let lastName: String
    let email: String
}

// ====

// === Dependencies: User Services ===

protocol UserService {
    func getData() async -> User?
}

struct MockUserService: UserService {
    
    let fakeUsers = [
        User(firstName: "John", lastName: "Doe", email: "johndoe@email.com"),
        User(firstName: "Lara", lastName: "Wood", email: "larawood@email.com"),
        User(firstName: "Mike", lastName: "Chen", email: "mikechen@email.com"),
        User(firstName: "Mara", lastName: "Rossi", email: "mararossi@email.com")
    ]
    
    func getData() async -> User? {
        try? await Task.sleep(for: .seconds(Double.random(in: 2..<5)))
        return fakeUsers.randomElement()
    }
}

// ===

// === Dependencies: Data Sources ===

protocol DataSource: Actor {
    var userSubject: CurrentValueSubject<User?, Never> { get set }
    func loadData() async -> Void
}

actor DataManager<US: UserService>: DataSource {
    
    var userSubject = CurrentValueSubject<User?, Never>(nil)
    let service: US
    
    init(service: US) {
        self.service = service
    }
    
    func loadData() async -> Void {
        for _ in 0..<10 {
            // Send value to the subscribers (`ContentViewModel`)
            self.userSubject.send(await self.service.getData())
        }
        
        // Send completion signals to subscribers
        self.userSubject.send(completion: .finished)
    }
}

// ===

// === View Model ===

@Observable
class ContentViewModel<DS: DataSource> {
    
    let userManager: DS
    @MainActor var users = [User?]()
    var cancellables: Set<AnyCancellable> = []
    
    init(userManager: DS) {
        
        self.userManager = userManager
        
        /*
         Instantiate an async stream using my `CustomAsyncStream` API
         to handle the `userSubject` publisher data source, sending
         data downstream over time.
         */
        let asyncStream = CustomAsyncStream<User?> { continuation in
            Task {
                await self.userManager.userSubject.sink { _ in
                    Task { await continuation.finish() }
                } receiveValue: { user in
                    Task { await continuation.yield(user) }
                }
                .store(in: &self.cancellables)
            }
        }
        
        // Appending user data from the async stream, over time, onto the
        // view model's `users` array
        Task {
            for await user in asyncStream {
                await MainActor.run {
                    self.users.append(user)
                }
            }
            
            print("Stream Completed!")
        }
    }
    
    /*
     Trigger our source of truth via the user manager, allowing
     to send user data down the stream to any subscriber.
     At which point, we are handling the subscription
     as well as the flow of data over time using our `CustomAsyncStream`
     providing an asynchronous interface and the usage of the `async/await`
     mechanism.
    */
    func loadUser() async {
        await self.userManager.loadData()
    }
}
// ===

// === View ===

struct ContentView: View {
    
    @State private var contentViewModel = ContentViewModel(userManager: DataManager(service: MockUserService()))
    
    var body: some View {
        ZStack {
            ScrollView {
                ForEach(contentViewModel.users, id: \.self) { user in
                    VStack {
                        if let user = user {
                            Text("\(user.firstName) \(user.lastName)")
                        }
                    }
                }
            }
        }
        .task {
            await contentViewModel.loadUser()
        }
    }
}

// ===

#Preview {
    ContentView()
}
```

That's all for today folks! I hope you enjoyed the reading, and don't hesitate to reach out to me
for any questions or suggestions!

Peace!
