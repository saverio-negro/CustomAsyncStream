//
//  ContentView.swift
//  CustomAsyncStream
//
//  Created by Saverio Negro on 4/10/26.
//

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
        NavigationStack {
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
            .navigationTitle("CustomAsyncStream")
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
