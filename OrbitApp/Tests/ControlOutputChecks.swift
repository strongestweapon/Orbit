import Foundation
import Network

final class Received {
    let lock=NSLock()
    private var udp:[Data]=[]
    private var deliveries:[ControlDelivery]=[]
    private var listenPort:UInt16?
    private var connections:[NWConnection]=[]
    func addUDP(_ data:Data) {lock.lock();udp.append(data);lock.unlock()}
    func addDelivery(_ value:ControlDelivery) {lock.lock();deliveries.append(value);lock.unlock()}
    func deliverySnapshot()->[ControlDelivery] {lock.lock();defer{lock.unlock()};return deliveries}
    func setPort(_ port:UInt16) {lock.lock();listenPort=port;lock.unlock()}
    func hold(_ connection:NWConnection) {lock.lock();connections.append(connection);lock.unlock()}
    func snapshot()->([Data],UInt16?) {lock.lock();defer{lock.unlock()};return (udp,listenPort)}
}

@main struct ControlOutputChecks {
    static func main() throws {
        let received=Received(),sender=ControlOutput()
        sender.onDelivery={received.addDelivery($0)}
        let listener=try NWListener(using:.udp,on:.any)
        let queue=DispatchQueue(label:"orbit-validation-udp")
        listener.stateUpdateHandler={state in if case .ready=state,let port=listener.port {received.setPort(port.rawValue)}}
        listener.newConnectionHandler={connection in
            received.hold(connection);connection.start(queue:queue);receive(connection,into:received)
        }
        listener.start(queue:queue);defer{listener.cancel()}
        wait("UDP listener ready"){received.snapshot().1 != nil}
        var osc=ParameterOutputRoute();osc.port=Int(received.snapshot().1!);osc.address="/orbit/test/speed"
        let message=ControlEmission(id:"speed",route:osc,value:0.25)
        sender.send([message])
        wait("OSC float packet"){received.snapshot().0.count==1 && received.deliverySnapshot().count==1}
        precondition(Array(received.snapshot().0[0].suffix(4))==[62,128,0,0],"Wrong OSC float wire value")
        let delivery=received.deliverySnapshot()[0]
        precondition(delivery.error==nil && delivery.value==0.25 && delivery.signal==osc.address && delivery.destination==osc.destinationKey)
        sender.send([message]);pump(0.2)
        precondition(received.snapshot().0.count==1 && received.deliverySnapshot().count==1,"Identical continuous frames must coalesce")
        sender.send([ControlEmission(id:"speed",route:osc,value:0.5)],force:true)
        wait("forced test"){received.snapshot().0.count==2 && received.deliverySnapshot().last?.value==0.5}
        precondition(Array(received.snapshot().0[1].suffix(4))==[63,0,0,0])
        sender.reset();sender.send([message])
        wait("reset/resume"){received.snapshot().0.count==3}
        var legacy=osc;legacy.transport = .midi;legacy.maximum=127
        sender.send([ControlEmission(id:"legacy",route:legacy,value:64)],force:true)
        sender.sendEvents([ControlEmission(id:"legacy",route:legacy,value:127)])
        pump(0.2);precondition(received.snapshot().0.count==3,"Legacy MIDI routes must not leak unnormalized data to UDP")
        var angle=osc;angle.address="/event/angle"
        var trigger=osc;trigger.address="/event/crossing"
        let event=[ControlEmission(id:"angle",route:angle,value:0.3),ControlEmission(id:"trigger",route:trigger,value:1)]
        for _ in 0..<3 {sender.sendEvents(event)}
        wait("repeated bundled events"){received.snapshot().0.count==6}
        let bundles=Array(received.snapshot().0.suffix(3))
        precondition(bundles.allSatisfy {$0.starts(with:Data("#bundle\0".utf8))})
        precondition(bundles.allSatisfy {OSCDecoder.decode($0).map(\.address)==["/event/angle","/event/crossing"]})
        precondition(bundles.allSatisfy {OSCDecoder.decode($0).last?.values==[1]})
        sender.send([],retaining:[trigger,angle]);pump(2.2)
        precondition(received.snapshot().0.count==6,"Events must not heartbeat/replay")
        sender.sendEvents(event,test:true)
        wait("event test on retained connection"){received.snapshot().0.count==7}
        print("PASS: OSC-only UDP float packets and delivery receipts, continuous coalescing, forced tests, reset/resume, legacy MIDI rejection, repeated bundles without heartbeat")
        withExtendedLifetime(sender) {}
    }
    static func receive(_ connection:NWConnection,into received:Received) {
        connection.receiveMessage {data,_,_,error in
            if let data {received.addUDP(data)}
            if error == nil {receive(connection,into:received)}
        }
    }
    static func wait(_ label:String,_ predicate:()->Bool) {
        let end=Date().addingTimeInterval(10)
        while !predicate(){precondition(Date()<end,label);pump(0.01)}
    }
    static func pump(_ duration:Double){RunLoop.current.run(until:Date().addingTimeInterval(duration))}
}
