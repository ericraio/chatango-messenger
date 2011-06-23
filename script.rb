require "./chatango_home.rb"
require "set"

$acc = ["crixia0226", "c0llegato"]

def lSent
	$sent = Set.new(File.read("sent").split(";"))
end

def sSent
	File.open("sent", "w") do |f|
		f.write($sent.to_a.join(";"))
	end
end

lSent

$ch = Chatango_Home.new("c1.chatango.com", "5222", nil, $acc[0], $acc[1])

msg = "Hey come check out my friends new anime site! http://www.animulu.com ^_^",

puts {"Logging in."}

trap("INT") do
	puts "Interrupted."
	exit
end

$ch.main() do |event, data|
	case(event)
		when "on_clist_load"
			puts "Logged in, performing search..."
			$usrs_raw = $ch.do_user_search({
				"ss" => "",
				"o" => "y",
				"i" => "y",
				"ama" => "150",
				"ami" => "13",
				"f" => "0",
				"t" => "5000",
				"c" => "",
				"s" => ""
			}).keys
			
			$usrs = (Set.new($usrs_raw) - Set.new($sent)).to_a
						
			puts "Done, users found: #{$usrs.join(", ")}"
			puts "Is this okay? (Y/N)"
			print "> "
			inp = $stdin.gets.chomp
			if(inp == "y" || inp == "Y")
				puts "Messaging."
			else
				puts "Aborting..."
				exit
			end
			
			i = 0
			
			Thread.new do
				$usrs.each do |usr|
				  puts "Messaging #{usr}"
					$ch.do_msg(usr, msg)
					$sent << usr
					sSent
					i += 1
					puts "#{usr} (#{i}/#{$usrs.length})"
					sleep(3)
				end
				sleep(3)
				$ch.do_disconnect
				puts "dun :3"
			end
		when "on_message"
			puts "#{data[:name]}: #{data[:msg]}"
	end
end
