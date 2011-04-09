# -*- encoding: utf-8 -*-

# A buffer that ensures frames are at least written to a
# {OnStomp::Client client}'s {OnStomp::Connections::Base connection} and
# replays the ones that were not when the
# {OnStomp::Failover::Client failover} client reconnects.
class OnStomp::Failover::Buffers::Written
  def initialize failover
    @failover = failover
    @buffer_mutex = Mutex.new
    @buffer = []
    @txs = {}

    failover.before_send &method(:buffer_frame)
    failover.before_commit &method(:buffer_frame)
    failover.before_abort &method(:buffer_frame)
    failover.before_subscribe &method(:buffer_frame)
    failover.before_begin &method(:buffer_transaction)
    # We can scrub the subscription before UNSUBSCRIBE is fully written
    # because if we replay before UNSUBSCRIBE was sent, we still don't
    # want to be subscribed when we reconnect.
    failover.before_unsubscribe &method(:debuffer_subscription)
    # We only want to scrub the transactions if ABORT or COMMIT was
    # at least written fully to the socket.
    failover.on_commit &method(:debuffer_transaction)
    failover.on_abort &method(:debuffer_transaction)
    failover.on_send &method(:debuffer_non_transactional_frame)
    
    failover.on_failover_connected &method(:replay)
  end
  
  # Adds a frame to a buffer so that it may be replayed if the
  # {OnStomp::Failover::Client failover} client re-connects
  def buffer_frame f, *_
    @buffer_mutex.synchronize do
      unless f.header? :'x-onstomp-failover-replay'
        @buffer << f 
      end
    end
  end
  
  # Records the start of a transaction so that it may be replayed if the
  # {OnStomp::Failover::Client failover} client re-connects
  def buffer_transaction f, *_
    @txs[f[:transaction]] = true
    buffer_frame f
  end
  
  # Removes the recorded transaction from the buffer after it has been
  # written the broker socket so that it will not be replayed when the
  # {OnStomp::Failover::Client failover} client re-connects
  def debuffer_transaction f, *_
    tx = f[:transaction]
    if @txs.delete tx
      @buffer_mutex.synchronize do
        @buffer.reject! { |bf| bf[:transaction] == tx }
      end
    end
  end
  
  # Removes the matching SUBSCRIBE frame from the buffer after the
  # UNSUBSCRIBE has been added to the connection's write buffer
  # so that it will not be replayed when the
  # {OnStomp::Failover::Client failover} client re-connects
  def debuffer_subscription f, *_
    @buffer_mutex.synchronize do
      @buffer.reject! { |bf| bf.command == 'SUBSCRIBE' && bf[:id] == f[:id] }
    end
  end
  
  # Removes a frame that is not part of a transaction from the buffer
  # after it has been written the broker socket so that it will not be
  # replayed when the {OnStomp::Failover::Client failover} client re-connects
  def debuffer_non_transactional_frame f, *_
    unless @txs.key?(f[:transaction])
      @buffer_mutex.synchronize { @buffer.delete f }
    end
  end
  
  # Called when the {OnStomp::Failover::Client failover} client triggers
  # `on_failover_connected` to start replaying any frames in the buffer.
  def replay fail, client, *_
    replay_frames = @buffer_mutex.synchronize do
      @buffer.select { |f| f[:'x-onstomp-failover-replay'] = '1'; true }
    end
    
    replay_frames.each do |f|
      client.transmit f
    end
  end
end