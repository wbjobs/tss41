import Foundation
import Starscream

protocol WebSocketManagerDelegate: AnyObject {
    func webSocketDidConnect(_ manager: WebSocketManager)
    func webSocketDidDisconnect(_ manager: WebSocketManager, error: Error?)
    func webSocket(_ manager: WebSocketManager, didReceiveMessage message: [String: Any])
    func webSocket(_ manager: WebSocketManager, didReceiveError error: Error)
}

class WebSocketManager: WebSocketDelegate {
    weak var delegate: WebSocketManagerDelegate?
    
    private var socket: WebSocket?
    private var url: URL
    private var isConnected = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private let reconnectDelay: TimeInterval = 2.0
    
    init(url: URL) {
        self.url = url
    }
    
    func connect() {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        
        socket = WebSocket(request: request)
        socket?.delegate = self
        socket?.connect()
    }
    
    func disconnect() {
        socket?.disconnect()
        socket = nil
        isConnected = false
    }
    
    func sendMessage(type: String, payload: [String: Any] = [:]) {
        guard isConnected else {
            print("WebSocket not connected, cannot send message")
            return
        }
        
        var message: [String: Any] = ["type": type]
        message.merge(payload) { (_, new) in new }
        
        do {
            let data = try JSONSerialization.data(withJSONObject: message, options: [])
            socket?.write(data: data)
        } catch {
            print("Error serializing message: \(error)")
            delegate?.webSocket(self, didReceiveError: error)
        }
    }
    
    func sendEncryptedMessage(encryptedData: [String: Any]) {
        sendMessage(type: "send_encrypted", payload: encryptedData)
    }
    
    func sendHeartbeat() {
        sendMessage(type: "heartbeat", payload: ["timestamp": Date().timeIntervalSince1970])
    }
    
    func isCurrentlyConnected() -> Bool {
        return isConnected
    }
    
    func didReceive(event: WebSocketEvent, client: WebSocket) {
        switch event {
        case .connected(let headers):
            isConnected = true
            reconnectAttempts = 0
            print("WebSocket connected: \(headers)")
            delegate?.webSocketDidConnect(self)
            
        case .disconnected(let reason, let code):
            isConnected = false
            print("WebSocket disconnected: \(reason), code: \(code)")
            delegate?.webSocketDidDisconnect(self, error: nil)
            
            attemptReconnect()
            
        case .text(let string):
            handleTextMessage(string)
            
        case .binary(let data):
            handleBinaryMessage(data)
            
        case .ping(_):
            break
            
        case .pong(_):
            break
            
        case .viabilityChanged(let viable):
            print("WebSocket viability changed: \(viable)")
            if !viable {
                isConnected = false
            }
            
        case .reconnectSuggested(let shouldReconnect):
            print("WebSocket reconnect suggested: \(shouldReconnect)")
            if shouldReconnect {
                attemptReconnect()
            }
            
        case .cancelled:
            isConnected = false
            delegate?.webSocketDidDisconnect(self, error: nil)
            
        case .error(let error):
            isConnected = false
            print("WebSocket error: \(error?.localizedDescription ?? "Unknown")")
            delegate?.webSocket(self, didReceiveError: error ?? NSError(domain: "WebSocket", code: -1))
            
            attemptReconnect()
        }
    }
    
    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else {
            print("Invalid text message encoding")
            return
        }
        
        do {
            if let message = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                delegate?.webSocket(self, didReceiveMessage: message)
            }
        } catch {
            print("Error parsing text message: \(error)")
        }
    }
    
    private func handleBinaryMessage(_ data: Data) {
        do {
            if let message = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                delegate?.webSocket(self, didReceiveMessage: message)
            }
        } catch {
            print("Error parsing binary message: \(error)")
        }
    }
    
    private func attemptReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            print("Max reconnect attempts reached")
            return
        }
        
        reconnectAttempts += 1
        print("Attempting reconnect \(reconnectAttempts)/\(maxReconnectAttempts)")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            self?.connect()
        }
    }
}
