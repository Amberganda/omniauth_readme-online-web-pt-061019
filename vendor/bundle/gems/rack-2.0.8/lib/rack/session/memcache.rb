# AUTHOR: blink <blinketje@gmail.com>; blink#ruby-lang@irc.freenode.net

require 'rack/session/abstract/id'
require 'memcache'

module Rack
  module Session
    # Rack::Session::Memcache provides simple cookie based session management.
    # Session data is stored in memcached. The corresponding session key is
    # maintained in the cookie.
    # You may treat Session::Memcache as you would Session::Pool with the
    # following caveats.
    #
    # * Setting :expire_after to 0 would note to the Memcache server to hang
    #   onto the session data until it would drop it according to it's own
    #   specifications. However, the cookie sent to the client would expire
    #   immediately.
    #
    # Note that memcache does drop data before it may be listed to expire. For
    # a full description of behaviour, please see memcache's documentation.

    class Memcache < Abstract::PersistedSecure
      attr_reader :mutex, :pool

      DEFAULT_OPTIONS = Abstract::ID::DEFAULT_OPTIONS.merge \
        :namespace => 'rack:session',
        :memcache_server => 'localhost:11211'

      def initialize(app, options={})
        super

        @mutex = Mutex.new
        mserv = @default_options[:memcache_server]
        mopts = @default_options.reject{|k,v| !MemCache::DEFAULT_OPTIONS.include? k }

        @pool = options[:cache] || MemCache.new(mserv, mopts)
        unless @pool.active? and @pool.servers.any?(&:alive?)
          raise 'No memcache servers'
        end
      end

      def generate_sid
        loop do
          sid = super
          break sid unless @pool.get(sid.private_id, true)
        end
      end

      def find_session(req, sid)
        with_lock(req) do
          unless sid and session = get_session_with_fallback(sid)
            sid, session = generate_sid, {}
            unless /^STORED/ =~ @pool.add(sid.private_id, session)
              raise "Session collision on '#{sid.inspect}'"
            end
          end
          [sid, session]
        end
      end

      def write_session(req, session_id, new_session, options)
        expiry = options[:expire_after]
        expiry = expiry.nil? ? 0 : expiry + 1

        with_lock(req) do
          @pool.set session_id.private_id, new_session, expiry
          session_id
        end
      end

      def delete_session(req, session_id, options)
        with_lock(req) do
          @pool.delete(session_id.public_id)
          @pool.delete(session_id.private_id)
          generate_sid unless options[:drop]
        end
      end

      def with_lock(req)
        @mutex.lock if req.multithread?
        yield
      rescue MemCache::MemCacheError, Errno::ECONNREFUSED
        if $VERBOSE
          warn "#{self} is unable to find memcached server."
          warn $!.inspect
        end
        raise
      ensure
        @mutex.unlock if @mutex.locked?
      end

      private

      def get_session_with_fallback(sid)
        @pool.get(sid.private_id) || @pool.get(sid.public_id)
      end
    end
  end
end
