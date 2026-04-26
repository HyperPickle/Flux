import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Text("Flux Battery Monitor")
                .font(.headline)
                .padding()
            
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .padding(.bottom)
        }
        .frame(width: 250, height: 150)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
