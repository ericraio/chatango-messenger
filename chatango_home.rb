#!/usr/bin/ruby

#Info on user searches
#Args:
#c => Country
#ama => Max age
#ami => Min age
#s => Sex
#ss => Name
#o => Online ("y" if true)
#i => Has picture ("y" if true)
#f => From
#t => To

#Info on profile update
#Args:
#checkerrors => No idea, should be set to "yes".
#uns => No idea either, set to "0".
#full_profile => Full profile.
#email => E-mail. -> Required.
#line => About me.
#encline => Urlencoded {line}.
#location => Country.
#gender => Gender, F is female, M if male, ? if not set.
#age => Age, number from 13 to 150. (excluding 150 and including 13)

require "socket";
require "net/http";
require "uri";

class Chatango_Home
	def initialize( server, port, authid=nil, name="", password="" )
		@serv = server;
		@port = port;
		if( authid )
			@name = nil;
			@password = nil;
			@auid = authid;
		else
			@auid = nil;
			@name = name;
			@password = password;
		end
		@version_id = 2;
		
		@id = nil;
		
		@clist = Hash.new();
		
		@event_block = nil;
		
		@sock = nil;
		
		@blist = Array.new();
		
		@ping_thread = nil;
	end
	
	def self.create_account( name, password, email )
		sock = TCPSocket.new( "chatango.com", 80 );
		
		data = "login=#{name}&password=#{password}&password_confirm=#{password}&signupsubmit=Sign+up&checkerrors=yes&email=#{email}";
		
		sock.write( "POST /signupdir HTTP/1.1\r\nHost: #{name}.chatango.com\r\nAccept: */*\r\nContent-length: #{data.length}\r\n\r\n#{data}" );
		
		data = sock.gets( "\r\n\r\n" );
		
		data_array = data.split( "\r\n" );
		
		auid = "";
		
		data_array.each do |ind|
			if( ind =~ /^Set-Cookie: auth\.chatango\.com=([^;]*)/ )
				auid = $~[1];
			end
		end
		
		auid;
	end
	
	def set_login_name( name, passwd )
		@auid = nil;
		@name = name;
		@password = passwd;
	end
	
	def set_login_auid( auid )
		@auid = auid;
		@name = nil;
		@password = nil;
	end
	
	def main( &block )
		@sock = TCPSocket.new( @serv, @port );
		
		@event_block = block;
		
		if( do_auth() )
			do_request_clist();
			do_request_blist();
			
			@event_block.call( "on_login_success", Hash.new() );
			
			@ping_thread = Thread.new do
				loop do
					sleep( 20 );
					do_ping();
				end
			end
			
			while( !@sock.closed? )
				data = @sock.gets( "\r\n\x00" );
				if( data )
					data = data[0..-4];
				else
					next;
				end
				
				if( data == "" || data == nil )
					@sock.write( "\r\n\x00" );
				else
					process_data( data );
				end
			end
		else
			@event_block.call( "on_login_failure", Hash.new() );
		end
	end
	
	def process_data( data )
		data_array = data.split( ":" );
		if( data[-1..-1] == ":" )
			data_array << nil;
		end
		
		case( data_array[0] )
			when "msg"
				@event_block.call( "on_message", { :msg => data_array[5..-1].join( ":" ), :name => data_array[1], :time => Time.at( data_array[4].to_i ), :is_old => false } );
			when "msgoff"
				@event_block.call( "on_message", { :msg => data_array[5..-1].join( ":" ), :name => data_array[1], :time => Time.at( data_array[4].to_i ), :is_old => true } );
			when "wl"
				ctdata = data_array[1..-1];
				
				ctdata = Array.new( ctdata.length / 4 ) do |idx|
					ctdata[(idx*4)..(idx*4+3)]
				end
				
				ctdata.each do |elem|
					@clist[ elem[0] ] = {
						:last_on => Time.at( elem[1].to_i ),
						:is_on => (elem[2] == "on"),
						:idle => (elem[3] == "1")
					};
				end
				
				@event_block.call( "on_clist_load", Hash.new() );
			when "wlonline"
				if( !@clist[ data_array[1] ] )
					@clist[ data_array[1] ] = Hash.new();
					usr = @clist[ data_array[1] ];
				else
					usr = @clist[ data_array[1] ];
				end
				usr[:last_on] = Time.at( data_array[2].to_i );
				usr[:is_on] = true;
				@event_block.call( "on_online_status_change", { :name => data_array[1], :time => Time.at( data_array[2].to_i ), :is_on => true } );
			when "wloffline"
				if( !@clist[ data_array[1] ] )
					@clist[ data_array[1] ] = Hash.new();
					usr = @clist[ data_array[1] ];
				else
					usr = @clist[ data_array[1] ];
				end
				usr[:last_on] = Time.at( data_array[2].to_i );
				usr[:is_on] = false;
				@event_block.call( "on_online_status_change", { :name => data_array[1], :time => Time.at( data_array[2].to_i ), :is_on => false } );
			when "idleupdate"
				if( !@clist[ data_array[1] ] )
					@clist[ data_array[1] ] = Hash.new();
					usr = @clist[ data_array[1] ];
				else
					usr = @clist[ data_array[1] ];
				end
				usr[:idle] = (data_array[2] == "1");
				@event_block.call( "on_idle_status_change", { :name => data_array[1], :idle => (data_array[2] == "1") } );
			when "reload_profile"
				@event_block.call( "on_profile_reload_request", { :name => data_array[1] } );
			when "wladd"
				if( !( in_list? data_array[1] ) && data_array[2] != "invalid" )
					@clist[ data_array[1].downcase ] = { :is_on => (data_array[2]=="on") };
				end
				@event_block.call( "on_contact_add", { :name => data_array[1], :is_on => data_array[2]=="on", :exists => ( data_array[2] != "invalid" ) } );
			when "wldelete"
				if( ( in_list? data_array[1] ) && data_array[2] == "deleted" )
					@clist.delete( data_array[1].downcase );
				end
				@event_block.call( "on_contact_delete", { :name => data_array[1], :deleted => data_array[2]=="deleted" } );
			when "block_list"
				@blist = data_array[1..-1];
				@event_block.call( "on_block_list_receive", { :list => data_array[1..-1] } );
			when "status"
				@event_block.call( "on_connection_status_change", { :name => data_array[1], :time => Time.at( data_array[2].to_i ), :is_on => (data_array[3] == "online") } );
			when "connect"
				@event_block.call( "on_connection_established", { :name => data_array[1], :idle_time => data_array[2].to_i, :is_on => (data_array[3] == "online"), :exists => (data_array[3] != "invalid") } );
		end
	end
	
	def do_auth()
		if( @auid == nil )
			@auid = Chatango_Home.request_auth_id( @name, @password );
			@password = nil;
		end
		
		@sock.write( "tlogin:#{@auid}:#{@version_id}\x00" );
		
		loop do
			data = @sock.gets( "\r\n\x00" );
			
			while( !data )
				data = @sock.gets( "\r\n\x00" );
			end
			
			data = data[0..-4];
			
			if( data == "DENIED" )
				return false;
			else
				data_array = data.split( ":" );
				if( data_array[0] == "seller_name" )
					@name = data_array[1];
					@id = data_array[2];
					
					return true;
				end
			end
		end
	end
	
	def self.request_auth_id( name, password )
		sock = TCPSocket.new( "chatango.com", 80 );
		
		data = "user_id=#{name}&password=#{password}&storecookies=on&checkerrors=yes";
		
		sock.write( "POST /login HTTP/1.1\r\nHost: chatango.com\r\nAccept: */*\r\nContent-length: #{data.length}\r\n\r\n#{data}" );
		
		data = sock.gets( "\r\n\r\n" );
		
		data_array = data.split( "\r\n" );
		
		data_array.each do |ind|
			if( ind =~ /^Set-Cookie: auth\.chatango\.com=([^;]*)/ )
				return $~[1];
			end
		end
	end
	
	#Commands
	def do_request_clist()
		@sock.write( "wl\r\n\x00" );
	end
	
	def do_msg( name, msg )
		@sock.write( "msg:#{name}:#{msg}\r\n\x00" );
	end
	
	def do_raw( msg )
		@sock.write( msg );
	end
	
	def do_ping()
		@sock.write( "\r\n\x00" );
	end
	
	def do_disconnect()
		if( @ping_thread )
			@ping_thread.kill();
		end
		if( @sock )
			unless( @sock.closed? )
				@sock.close();
			end
		end
	end
	
	def do_add( name )
		@sock.write( "wladd:#{name}\r\n\x00" );
	end
	
	def do_rem( name )
		@sock.write( "wldelete:#{name}\r\n\x00" );
	end
	
	def do_init_conversation( name )
		@sock.write( "connect:#{name}\r\n\x00" );
	end
	
	def do_destroy_conversation( name )
		@sock.write( "disconnect:#{name}\r\n\x00" );
	end
	
	def do_request_blist()
		@sock.write( "getblock\r\n\x00" );
	end
	
	def do_block( name )
		unless( @blist.include? name )
			@blist << name;
			
			@sock.write( "block:#{name}:#{name}:S\r\n\x00" );
			
			@event_block.call( "on_block", { :name => name } );
		end
	end
	
	def do_unblock( name )
		if( @blist.include? name )
			@blist.delete( name );
			
			@sock.write( "unblock:#{name}\r\n\x00" );
			
			@event_block.call( "on_unblock", { :name => name } );
		end
	end
	
	#Request data
	def do_get_profile_img( name )
		url = "http://pst.chatango.com/profileimg/#{name[0..0]}/#{name[1..1]}/#{name}/thumb.jpg";
		
		url = URI.parse( url );
		
		Net::HTTP.get( url );
	end
	
	def do_get_profile_img_to_file( file, name )
		File.open( file, "w" ) do |f|
			f.write( do_get_profile_img( name ) );
		end
	end
	
	def do_get_full_img( name )
		url = "http://pst.chatango.com/profileimg/#{name[0..0]}/#{name[1..1]}/#{name}/full.jpg";
		
		url = URI.parse( url );
		
		Net::HTTP.get( url );
	end
	
	def do_get_full_img_to_file( file, name )
		File.open( file, "w" ) do |f|
			f.write( do_get_full_img( name ) );
		end
	end
	
	def do_get_raw_profile_info( name )
		url = "http://st.chatango.com/profileimg/#{name[0..0]}/#{name[1..1]}/#{name}/mod1.xml";
		
		url = URI.parse( url );
		
		Net::HTTP.get( url );
	end
	
	def do_get_raw_profile_info_to_file( file, name )
		File.open( file, "w" ) do |f|
			f.write( do_get_raw_profile_info( name ) );
		end
	end
	
	def do_get_raw_full_profile_info( name )
		url = "http://st.chatango.com/profileimg/#{name[0..0]}/#{name[1..1]}/#{name}/mod2.xml";
		
		url = URI.parse( url );
		
		Net::HTTP.get( url );
	end
	
	def do_get_raw_full_profile_info_to_file( file, name )
		File.open( file, "w" ) do |f|
			f.write( do_get_raw_profile_info( name ) );
		end
	end
	
	def do_get_profile_info( name )
		profile_xml = do_get_raw_profile_info( name );
		
		profile_xml.gsub!( /%(..)/ ) do |match|
			match[1..-1].to_i( 16 ).chr;
		end
		
		#Pro
		if( profile_xml =~ /<body>(.*)<\/body>/ )
			pro = $~[1];
			profile_xml[ $~[0] ] = "";
		else
			pro = nil;
		end
		
		#Age
		if( profile_xml =~ /<a>(.*)<\/a>/ )
			age = $~[1];
		else
			age = nil;
		end
		
		#Sex
		if( profile_xml =~ /<s>(.*)<\/s>/ )
			sex = $~[1];
		else
			sex = nil;
		end
		
		#Location
		if( profile_xml =~ /<l[^>]*>(.*)<\/l>/ )
			loc = $~[1];
		else
			loc = nil;
		end
		
		return {
			:age => age,
			:sex => sex,
			:loc => loc,
			:pro => pro
		}
	end
	
	def do_get_full_profile_info( name )
		profile_xml = do_get_raw_full_profile_info( name );
		
		profile_xml.gsub!( /%(..)/ ) do |match|
			match[1..-1].to_i( 16 ).chr;
		end
		
		if( profile_xml =~ /<body>(.*)<\/body>/ )
			pro = $~[1];
			profile_xml[ $~[0] ] = "";
		else
			pro = nil;
		end
		
		return {
			:pro => pro
		}
	end
	
	def do_get_email()
		url = URI.parse( "http://www.chatango.com/myinfo" )
		res = Net::HTTP.start( url.host, url.port ) do |http|
			http.get( "/myinfo", {
				"cookie" => "auth.chatango.com=#{@auid}"
			} );
		end
		
		/email=([^&]*)/.match( res.body )[1];
	end
	
	def do_edit_profile_info( params )
		data = Array.new();
		
		params.each do |var, val|
			data << "#{var}=#{val}";
		end
		
		data = data.join( "&" );
		
		data.gsub!( "\r\n", "\r" );
		data.gsub!( "\n", "\r" );
		
		url = URI.parse( "http://www.chatango.com/updateprofile" )
		res = Net::HTTP.start( url.host, url.port ) do |http|
			http.post( "/updateprofile?flash&d&s=#{@auid}", data, {
				"cookie" => "auth.chatango.com=#{@auid}",
				"pragma" => "no-cache",
				"cache-control" => "no-cache"
			} );
		end
		
		if( res.body == "None" || res.body == nil )
			return nil;
		end
		
		data = res.body;
		
		hsh = Hash.new();
		
		data.split( "&" ).each do |ind|
			ind.gsub!( /%../ ) do |match|
				match[1..-1].to_i( 16 ).chr;
			end
			
			key, data = ind.split( "=", 2 );
			
			hsh[key] = data;
		end
		
		hsh;
	end
	
	def do_user_search( params )
		data = Array.new();
		
		params.each do |var, val|
			data << "#{var}=#{val}";
		end
		
		data = data.join( "&" );
		
		url = URI.parse( "http://www.chatango.com/flashdir" )
		res = Net::HTTP.start( url.host, url.port ) do |http|
			http.post( "/flashdir", data, {
				"cookie" => "auth.chatango.com=#{@auid}"
			} );
		end
		
		if( res.body == "None" || res.body == nil )
			return nil;
		end
		
		usrs = res.body[2..-1];
		
		hsh = Hash.new();
		
		usrs.split( ":" ).each do |ind|
			usr, is_on = ind.split( ";" );
			
			is_on = ( is_on == "1" );
			
			hsh[ usr ] = { :is_on => is_on };
		end
		
		hsh;
	end
	
	#Requests
	def get_clist()
		@clist;
	end
	
	def in_list?( name )
		( @clist[ name ] != nil );
	end
	
	def get_blist()
		@blist;
	end
	
	def is_blocked?( name )
		@blist.include? name;
	end
	
	def get_name()
		@name;
	end
end