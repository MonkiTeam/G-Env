-- services
local run_service = game:GetService("RunService")

-- imports
local bridge = (function()
	local bridge_parent = game:GetService("RobloxReplicatedStorage")
	local http_service = game:GetService("HttpService")

	local data_maxlen = 199998
	local PAYLOAD_MATCH = "^%x+"
	local PAYLOAD_TEMPLATE = "%08X|%s"

	local step_sim = game:GetService("RunService").PreSimulation
	local sending_value_whitelist = { "string", "number", "Instance", "boolean", "table" }

	local channel_template
	do
		channel_template = Instance.new("Folder")

		local peer0_container = Instance.new("Folder") -- roblox container
		peer0_container.Name = "Peer0"
		peer0_container.Parent = channel_template

		local peer1_container = Instance.new("Folder") -- external container
		peer1_container.Name = "Peer1"
		peer1_container.Parent = channel_template

		local instance_refs = Instance.new("Folder")
		instance_refs.Name = "InstanceRefs"
		instance_refs.Parent = channel_template

		local channel_states = Instance.new("NumberValue")
		channel_states.Name = "States"
		channel_states.Parent = channel_template

		-- precreation of StringValues
		-- roughly 16mb+ when combined

		for idx = 0, 8 do
			local peer0_str = Instance.new("StringValue", peer0_container)
			local peer1_str = Instance.new("StringValue", peer1_container)

			peer0_str.Name, peer1_str.Name = idx, idx
			peer0_str.Value = string.rep("\128", 20)
			peer1_str.Value = string.rep("\128", data_maxlen) -- peer1 (external peer) stringvalue is preallocated
		end
	end

	local bridge = {
		main_container = Instance.new("Folder"),

		module_holder = Instance.new("ObjectValue"),
		executing_script = nil,

		channels_container = Instance.new("Folder"),

		sessions = {},
		queued_datas = {},

		recieved_actions_list = {},
		action_callbacks = {},
	}

	local function encode_channel_states(
		channel_states: NumberValue,
		is_used: boolean,
		responding: boolean,
		responded: boolean,
		sender: number
	)
		local result = bit32.band((if is_used then 1 else 0), 0b0001)
		result += bit32.band(bit32.lshift((if responding then 1 else 0), 1), 0b0010)
		result += bit32.band(bit32.lshift((if responded then 1 else 0), 2), 0b0100)
		result += bit32.band(bit32.lshift(sender, 3), 0b1000)

		channel_states.Value = result
	end

	local function decode_channel_states(channel_states: NumberValue): (boolean, boolean, boolean, number?)
		local packed_states = channel_states.Value

		local is_used = bit32.extract(packed_states, 0, 1) == 1
		local responding = bit32.extract(packed_states, 1, 1) == 1
		local responded = bit32.extract(packed_states, 2, 1) == 1
		local sender = bit32.extract(packed_states, 3, 1) -- 0 = roblox | 1 = external
		return is_used, responding, responded, (if is_used then sender else nil)
	end

	local function get_available_channel(): Folder?
		for _, channel in bridge.channels_container:GetChildren() do
			local is_used = decode_channel_states(channel.States)
			if is_used then
				continue
			end

			return channel
		end
		return nil
	end

	local function combine_buffers(container: Folder): string?
		local children_count = #container:GetChildren()
		local result = ""

		for idx = 0, (children_count - 1) do
			local buffer = container:FindFirstChild(tostring(idx))
			result ..= string.sub(buffer.Value, 1, data_maxlen) -- ensures that there is no \0 included at the end
		end

		if #result < 1 then
			return nil
		end

		local buffer_size = string.match(result, PAYLOAD_MATCH, 1)
		local buffer_match_len = (if buffer_size then #buffer_size else -1)
		buffer_size = (if buffer_size then tonumber(string.sub(buffer_size, 1, 8), 16) else nil)
		if not buffer_size then
			warn(`Failed to get buffer size of '{result}'`)
			return nil
		end

		return string.sub(
			result,
			(buffer_match_len + 2),
			(buffer_size + buffer_match_len) + ((buffer_size // data_maxlen) + 1)
		)
	end

	local function process_sending_data(channel: Folder, action: string, session: number, args: { any }): string
		local instance_refs: Folder = channel.InstanceRefs
		local current_reference_count = 0
		local raw_data do
			raw_data = {
				action,
				session,
				{},
			}

			for _, value in args do
				local value_type = typeof(value)
				if not (table.find(sending_value_whitelist, value_type)) then
					continue
				end

				if value_type == "Instance" then
					local current_referencer = instance_refs:FindFirstChild(current_reference_count)
					if not current_referencer then
						current_referencer = Instance.new("ObjectValue", instance_refs)
						current_referencer.Name = current_reference_count
					end

					current_referencer.Value = value
					table.insert(raw_data[3], { value_type, current_reference_count })
					current_reference_count += 1
					continue
				elseif value_type == "table" then
					value = http_service:JSONEncode(value)
				end

				table.insert(raw_data[3], { value_type, value })
			end
		end

		local encoded_data = http_service:JSONEncode(raw_data)
		local payload_len = utf8.len(encoded_data)
		encoded_data = string.format(PAYLOAD_TEMPLATE, payload_len, encoded_data)

		for buffer_pos = 1, payload_len, data_maxlen do
			local buffer_idx = buffer_pos // data_maxlen

			local current_buffer = channel.Peer0:FindFirstChild(buffer_idx)
			if not current_buffer then
				current_buffer = Instance.new("StringValue", channel.Peer0)
				current_buffer.Name = buffer_idx
			end

			current_buffer.Value = string.sub(encoded_data, buffer_pos, buffer_pos + data_maxlen)
		end
		encode_channel_states(channel.States, true, false, false, 0) -- sending data to external
	end

	local function process_recieving_data(channel: Folder, responded: boolean)
		encode_channel_states(channel.States, false, false, false, 0)
		local raw_data = combine_buffers(channel.Peer1)
		if not (raw_data and #raw_data > 0) then
			return
		end

		local success, recieved_data = pcall(http_service.JSONDecode, http_service, raw_data)
		if not success then
			warn(`Failed to decode recieved data of channel '{channel.Name}', data: {raw_data}`)
			return
		end

		local action, session, args = unpack(recieved_data)

		if responded then
			local recieved_actions = bridge.recieved_actions_list[action]
			if not recieved_actions then
				recieved_actions = {}
				bridge.recieved_actions_list[action] = recieved_actions
			end

			recieved_actions[session] = args
		else
			local action_func = bridge.action_callbacks[action]

			if action_func then
				task.spawn(action_func, args)
			end
		end
	end

	bridge.send = function(self, action, ...)
		if not action then
			return
		end

		local session = self.sessions[action] or 0
		self.sessions[action] = session + 1

		table.insert(self.queued_datas, { action, session, { ... } })

		local actions_list = bridge.recieved_actions_list[action]
		if not actions_list then
			actions_list = {}
			bridge.recieved_actions_list[action] = actions_list
		end

		local action_data
		repeat
			action_data = actions_list[session]
			step_sim:Wait()
		until action_data
		return unpack(action_data)
	end

	bridge.wait = function(self, action, timeout)
		timeout = timeout or 5
		local current_session = self.sessions[action] or 0

		local recieved_actions = bridge.recieved_actions_list[action]
		if not recieved_actions then
			recieved_actions = {}
			bridge.recieved_actions_list[action] = recieved_actions
		end

		local start_time = os.clock()
		local action_data

		repeat
			action_data = recieved_actions[current_session]
			step_sim:Wait()
		until action_data or (os.clock() - start_time) > timeout
		return unpack(action_data)
	end

	bridge.register_callback = function(self, callback_name, func)
		self.action_callbacks[callback_name] = func
	end

	bridge.queue_scheduler = step_sim:Connect(function()
		if #bridge.queued_datas < 1 then
			return
		end

		local channel = get_available_channel()
		if not channel then
			return
		end

		local passing_data = table.remove(bridge.queued_datas, 1)
		task.defer(process_sending_data, channel, unpack(passing_data))
	end)

	bridge.listener = step_sim:Connect(function()
		for _, channel in bridge.channels_container:GetChildren() do
			local is_used, responding, responded, sender = decode_channel_states(channel.States)
			if (sender == 1 and responding) or sender == 0 or not is_used then
				continue
			end

			task.defer(process_recieving_data, channel, responded)
		end
	end)

	for channel_idx = 0, 7 do
		local channel = channel_template:Clone()
		channel.Name = channel_idx
		channel.Parent = bridge.channels_container
	end

	bridge.module_holder.Name = "ModuleHolder"
	bridge.module_holder.Parent = bridge.main_container

	bridge.channels_container.Name = "Channels"
	bridge.channels_container.Parent = bridge.main_container

	bridge.main_container.Name = "Bridge"
	bridge.main_container.RobloxLocked = true
	bridge.main_container.Parent = bridge_parent

	return bridge

end)()
local aes = (function()
	--[[
ADVANCED ENCRYPTION STANDARD (AES)

Implementation of secure symmetric-key encryption specifically in Luau
Includes ECB, CBC, PCBC, CFB, OFB and CTR modes without padding.
Made by @RobloxGamerPro200007 (verify the original asset)

MORE INFORMATION: https://devforum.roblox.com/t/advanced-encryption-standard-in-luau/2009120
]]
	-- Taken from https://devforum.roblox.com/t/advanced-encryption-standard-in-luau/ WITH PATCHES

	-- SUBSTITUTION BOXES
	local s_box 	= { 99, 124, 119, 123, 242, 107, 111, 197,  48,   1, 103,  43, 254, 215, 171, 118, 202,
		130, 201, 125, 250,  89,  71, 240, 173, 212, 162, 175, 156, 164, 114, 192, 183, 253, 147,  38,  54,
		63, 247, 204,  52, 165, 229, 241, 113, 216,  49,  21,   4, 199,  35, 195,  24, 150,   5, 154,   7,
		18, 128, 226, 235,  39, 178, 117,   9, 131,  44,  26,  27, 110,  90, 160,  82,  59, 214, 179,  41,
		227,  47, 132,  83, 209,   0, 237,  32, 252, 177,  91, 106, 203, 190,  57,  74,  76,  88, 207, 208,
		239, 170, 251,  67,  77,  51, 133,  69, 249,   2, 127,  80,  60, 159, 168,  81, 163,  64, 143, 146,
		157,  56, 245, 188, 182, 218,  33,  16, 255, 243, 210, 205,  12,  19, 236,  95, 151,  68,  23, 196,
		167, 126,  61, 100,  93,  25, 115,  96, 129,  79, 220,  34,  42, 144, 136,  70, 238, 184,  20, 222,
		94,  11, 219, 224,  50,  58,  10,  73,   6,  36,  92, 194, 211, 172,  98, 145, 149, 228, 121, 231,
		200,  55, 109, 141, 213,  78, 169, 108,  86, 244, 234, 101, 122, 174,   8, 186, 120,  37,  46,  28,
		166, 180, 198, 232, 221, 116,  31,  75, 189, 139, 138, 112,  62, 181, 102,  72,   3, 246,  14,  97,
		53,  87, 185, 134, 193,  29, 158, 225, 248, 152,  17, 105, 217, 142, 148, 155,  30, 135, 233, 206,
		85,  40, 223, 140, 161, 137,  13, 191, 230,  66, 104,  65, 153,  45,  15, 176,  84, 187,  22}
	local inv_s_box	= { 82,   9, 106, 213,  48,  54, 165,  56, 191,  64, 163, 158, 129, 243, 215, 251, 124,
		227,  57, 130, 155,  47, 255, 135,  52, 142,  67,  68, 196, 222, 233, 203,  84, 123, 148,  50, 166,
		194,  35,  61, 238,  76, 149,  11,  66, 250, 195,  78,   8,  46, 161, 102,  40, 217,  36, 178, 118,
		91, 162,  73, 109, 139, 209,  37, 114, 248, 246, 100, 134, 104, 152,  22, 212, 164,  92, 204,  93,
		101, 182, 146, 108, 112,  72,  80, 253, 237, 185, 218,  94,  21,  70,  87, 167, 141, 157, 132, 144,
		216, 171,   0, 140, 188, 211,  10, 247, 228,  88,   5, 184, 179,  69,   6, 208,  44,  30, 143, 202,
		63,  15,   2, 193, 175, 189,   3,   1,  19, 138, 107,  58, 145,  17,  65,  79, 103, 220, 234, 151,
		242, 207, 206, 240, 180, 230, 115, 150, 172, 116,  34, 231, 173,  53, 133, 226, 249,  55, 232,  28,
		117, 223, 110,  71, 241,  26, 113,  29,  41, 197, 137, 111, 183,  98,  14, 170,  24, 190,  27, 252,
		86,  62,  75, 198, 210, 121,  32, 154, 219, 192, 254, 120, 205,  90, 244,  31, 221, 168,  51, 136,
		7, 199,  49, 177,  18,  16,  89,  39, 128, 236,  95,  96,  81, 127, 169,  25, 181,  74,  13,  45,
		229, 122, 159, 147, 201, 156, 239, 160, 224,  59,  77, 174,  42, 245, 176, 200, 235, 187,  60, 131,
		83, 153,  97,  23,  43,   4, 126, 186, 119, 214,  38, 225, 105,  20,  99,  85,  33,  12, 125}

	-- ROUND CONSTANTS ARRAY
	local rcon = {  0,   1,   2,   4,   8,  16,  32,  64, 128,  27,  54, 108, 216, 171,  77, 154,  47,  94,
		188,  99, 198, 151,  53, 106, 212, 179, 125, 250, 239, 197, 145,  57}
	-- MULTIPLICATION OF BINARY POLYNOMIAL
	local function xtime(x)
		local i = bit32.lshift(x, 1)
		return if bit32.band(x, 128) == 0 then i else bit32.bxor(i, 27) % 256
	end

	-- TRANSFORMATION FUNCTIONS
	local function subBytes		(s, inv) 		-- Processes State using the S-box
		inv = if inv then inv_s_box else s_box
		for i = 1, 4 do
			for j = 1, 4 do
				s[i][j] = inv[s[i][j] + 1]
			end
		end
	end
	local function shiftRows		(s, inv) 	-- Processes State by circularly shifting rows
		s[1][3], s[2][3], s[3][3], s[4][3] = s[3][3], s[4][3], s[1][3], s[2][3]
		if inv then
			s[1][2], s[2][2], s[3][2], s[4][2] = s[4][2], s[1][2], s[2][2], s[3][2]
			s[1][4], s[2][4], s[3][4], s[4][4] = s[2][4], s[3][4], s[4][4], s[1][4]
		else
			s[1][2], s[2][2], s[3][2], s[4][2] = s[2][2], s[3][2], s[4][2], s[1][2]
			s[1][4], s[2][4], s[3][4], s[4][4] = s[4][4], s[1][4], s[2][4], s[3][4]
		end
	end
	local function addRoundKey	(s, k) 			-- Processes Cipher by adding a round key to the State
		for i = 1, 4 do
			for j = 1, 4 do
				s[i][j] = bit32.bxor(s[i][j], k[i][j])
			end
		end
	end
	local function mixColumns	(s, inv) 		-- Processes Cipher by taking and mixing State columns
		local t, u
		if inv then
			for i = 1, 4 do
				t = xtime(xtime(bit32.bxor(s[i][1], s[i][3])))
				u = xtime(xtime(bit32.bxor(s[i][2], s[i][4])))
				s[i][1], s[i][2] = bit32.bxor(s[i][1], t), bit32.bxor(s[i][2], u)
				s[i][3], s[i][4] = bit32.bxor(s[i][3], t), bit32.bxor(s[i][4], u)
			end
		end

		local i
		for j = 1, 4 do
			i = s[j]
			t, u = bit32.bxor		(i[1], i[2], i[3], i[4]), i[1]
			for k = 1, 4 do
				i[k] = bit32.bxor	(i[k], t, xtime(bit32.bxor(i[k], i[k + 1] or u)))
			end
		end
	end

	-- BYTE ARRAY UTILITIES
	local function bytesToMatrix	(t, c, inv) -- Converts a byte array to a 4x4 matrix
		if inv then
			table.move		(c[1], 1, 4, 1, t)
			table.move		(c[2], 1, 4, 5, t)
			table.move		(c[3], 1, 4, 9, t)
			table.move		(c[4], 1, 4, 13, t)
		else
			for i = 1, #c / 4 do
				table.clear	(t[i])
				table.move	(c, i * 4 - 3, i * 4, 1, t[i])
			end
		end

		return t
	end
	local function xorBytes		(t, a, b) 		-- Returns bitwise XOR of all their bytes
		table.clear		(t)

		for i = 1, math.min(#a, #b) do
			table.insert(t, bit32.bxor(a[i], b[i]))
		end
		return t
	end
	local function incBytes		(a, inv)		-- Increment byte array by one
		local o = true
		for i = if inv then 1 else #a, if inv then #a else 1, if inv then 1 else - 1 do
			if a[i] == 255 then
				a[i] = 0
			else
				a[i] += 1
				o = false
				break
			end
		end

		return o, a
	end

	-- MAIN ALGORITHM
	local function expandKey	(key) 				-- Key expansion
		local kc = bytesToMatrix(if #key == 16 then {{}, {}, {}, {}} elseif #key == 24 then {{}, {}, {}, {}
			, {}, {}} else {{}, {}, {}, {}, {}, {}, {}, {}}, key)
		local is = #key / 4
		local i, t, w = 2, {}, nil

		while #kc < (#key / 4 + 7) * 4 do
			w = table.clone	(kc[#kc])
			if #kc % is == 0 then
				table.insert(w, table.remove(w, 1))
				for j = 1, 4 do
					w[j] = s_box[w[j] + 1]
				end
				w[1]	 = bit32.bxor(w[1], rcon[i])
				i 	+= 1
			elseif #key == 32 and #kc % is == 4 then
				for j = 1, 4 do
					w[j] = s_box[w[j] + 1]
				end
			end

			table.clear	(t)
			xorBytes	(w, table.move(w, 1, 4, 1, t), kc[#kc - is + 1])
			table.insert(kc, w)
		end

		table.clear		(t)
		for i = 1, #kc / 4 do
			table.insert(t, {})
			table.move	(kc, i * 4 - 3, i * 4, 1, t[#t])
		end
		return t
	end
	local function encrypt	(key, km, pt, ps, r) 	-- Block cipher encryption
		bytesToMatrix	(ps, pt)
		addRoundKey		(ps, km[1])

		for i = 2, #key / 4 + 6 do
			subBytes	(ps)
			shiftRows	(ps)
			mixColumns	(ps)
			addRoundKey	(ps, km[i])
		end
		subBytes		(ps)
		shiftRows		(ps)
		addRoundKey		(ps, km[#km])

		return bytesToMatrix(r, ps, true)
	end
	local function decrypt	(key, km, ct, cs, r) 	-- Block cipher decryption
		bytesToMatrix	(cs, ct)

		addRoundKey		(cs, km[#km])
		shiftRows		(cs, true)
		subBytes		(cs, true)
		for i = #key / 4 + 6, 2, - 1 do
			addRoundKey	(cs, km[i])
			mixColumns	(cs, true)
			shiftRows	(cs, true)
			subBytes	(cs, true)
		end

		addRoundKey		(cs, km[1])
		return bytesToMatrix(r, cs, true)
	end

	-- INITIALIZATION FUNCTIONS
	local function convertType	(a) 					-- Converts data to bytes if possible
		if type(a) == "string" then
			local r = {}

			for i = 1, string.len(a), 7997 do
				table.move({string.byte(a, i, i + 7996)}, 1, 7997, i, r)
			end
			return r
		elseif type(a) == "table" then
			for _, i in a do
				assert(type(i) == "number" and math.floor(i) == i and 0 <= i and i < 256,
					"Unable to cast value to bytes")
			end
			return a
		else
			error("Unable to cast value to bytes")
		end
	end
	local function deepCopy(Original)
		local copy = {}
		for key, val in Original do
			local Type = typeof(val)
			if Type == "table" then
				val = deepCopy(val)
			end
			copy[key] = val
		end
		return copy
	end
	local function init			(key, txt, m, iv, s) 	-- Initializes functions if possible
		key = convertType(key)
		assert(#key == 16 or #key == 24 or #key == 32, "Key must be either 16, 24 or 32 bytes long")
		txt = convertType(txt)
		assert(#txt % (s or 16) == 0, "Input must be a multiple of " .. (if s then "segment size " .. s
			else "16") .. " bytes in length")
		if m then
			if type(iv) == "table" then
				iv = table.clone(iv)
				local l, e 		= iv.Length, iv.LittleEndian
				assert(type(l) == "number" and 0 < l and l <= 16,
					"Counter value length must be between 1 and 16 bytes")
				iv.Prefix 		= convertType(iv.Prefix or {})
				iv.Suffix 		= convertType(iv.Suffix or {})
				assert(#iv.Prefix + #iv.Suffix + l == 16, "Counter must be 16 bytes long")
				iv.InitValue 	= if iv.InitValue == nil then {1} else table.clone(convertType(iv.InitValue
				))
				assert(#iv.InitValue <= l, "Initial value length must be of the counter value")
				iv.InitOverflow = if iv.InitOverflow == nil then table.create(l, 0) else table.clone(
				convertType(iv.InitOverflow))
				assert(#iv.InitOverflow <= l,
					"Initial overflow value length must be of the counter value")
				for _ = 1, l - #iv.InitValue do
					table.insert(iv.InitValue, 1 + if e then #iv.InitValue else 0, 0)
				end
				for _ = 1, l - #iv.InitOverflow do
					table.insert(iv.InitOverflow, 1 + if e then #iv.InitOverflow else 0, 0)
				end
			elseif type(iv) ~= "function" then
				local i, t = if iv then convertType(iv) else table.create(16, 0), {}
				assert(#i == 16, "Counter must be 16 bytes long")
				iv = {Length = 16, Prefix = t, Suffix = t, InitValue = i,
					InitOverflow = table.create(16, 0)}
			end
		elseif m == false then
			iv 	= if iv == nil then  table.create(16, 0) else convertType(iv)
			assert(#iv == 16, "Initialization vector must be 16 bytes long")
		end
		if s then
			s = math.floor(tonumber(s) or 1)
			assert(type(s) == "number" and 0 < s and s <= 16, "Segment size must be between 1 and 16 bytes"
			)
		end

		return key, txt, expandKey(key), iv, s
	end
	type bytes = {number} -- Type instance of a valid bytes object

	-- CIPHER MODES OF OPERATION
	return {
		-- Electronic codebook (ECB)
		encrypt_ECB = function(key : bytes, plainText : bytes, initVector : bytes?) 									: bytes
			local km
			key, plainText, km, initVector = init(key, plainText, false, initVector)

			local iv = deepCopy(initVector)
			local b, k, s, t = {}, {}, {{}, {}, {}, {}}, {}
			for i = 1, #plainText, 16 do
				table.move(plainText, i, i + 15, 1, k)
				table.move(encrypt(key, km, k, s, t), 1, 16, i, b)
			end

			return b, iv
		end,
		decrypt_ECB = function(key : bytes, cipherText : bytes, initVector : bytes?) 								: bytes
			local km
			key, cipherText, km = init(key, cipherText, false, initVector)

			local b, k, s, t = {}, {}, {{}, {}, {}, {}}, {}
			for i = 1, #cipherText, 16 do
				table.move(cipherText, i, i + 15, 1, k)
				table.move(decrypt(key, km, k, s, t), 1, 16, i, b)
			end

			return b
		end,
		-- Cipher block chaining (CBC)
		encrypt_CBC = function(key : bytes, plainText : bytes, initVector : bytes?) 			: bytes
			local km
			key, plainText, km, initVector = init(key, plainText, false, initVector)
			local iv = deepCopy(initVector)
			local b, k, p, s, t = {}, {}, initVector, {{}, {}, {}, {}}, {}
			for i = 1, #plainText, 16 do
				table.move(plainText, i, i + 15, 1, k)
				table.move(encrypt(key, km, xorBytes(t, k, p), s, p), 1, 16, i, b)
			end

			return b, iv
		end,
		decrypt_CBC = function(key : bytes, cipherText : bytes, initVector : bytes?) 			: bytes
			local km
			key, cipherText, km, initVector = init(key, cipherText, false, initVector)

			local b, k, p, s, t = {}, {}, initVector, {{}, {}, {}, {}}, {}
			for i = 1, #cipherText, 16 do
				table.move(cipherText, i, i + 15, 1, k)
				table.move(xorBytes(k, decrypt(key, km, k, s, t), p), 1, 16, i, b)
				table.move(cipherText, i, i + 15, 1, p)
			end

			return b
		end,
		-- Propagating cipher block chaining (PCBC)
		encrypt_PCBC = function(key : bytes, plainText : bytes, initVector : bytes?) 			: bytes
			local km
			key, plainText, km, initVector = init(key, plainText, false, initVector)
			local iv = deepCopy(initVector)
			local b, k, c, p, s, t = {}, {}, initVector, table.create(16, 0), {{}, {}, {}, {}}, {}
			for i = 1, #plainText, 16 do
				table.move(plainText, i, i + 15, 1, k)
				table.move(encrypt(key, km, xorBytes(k, xorBytes(t, c, k), p), s, c), 1, 16, i, b)
				table.move(plainText, i, i + 15, 1, p)
			end

			return b, iv
		end,
		decrypt_PCBC = function(key : bytes, cipherText : bytes, initVector : bytes?) 			: bytes
			local km
			key, cipherText, km, initVector = init(key, cipherText, false, initVector)

			local b, k, c, p, s, t = {}, {}, initVector, table.create(16, 0), {{}, {}, {}, {}}, {}
			for i = 1, #cipherText, 16 do
				table.move(cipherText, i, i + 15, 1, k)
				table.move(xorBytes(p, decrypt(key, km, k, s, t), xorBytes(k, c, p)), 1, 16, i, b)
				table.move(cipherText, i, i + 15, 1, c)
			end

			return b
		end,
		-- Cipher feedback (CFB)
		encrypt_CFB = function(key : bytes, plainText : bytes, initVector : bytes?, segmentSize : number?)
			: bytes
			local km
			key, plainText, km, initVector, segmentSize = init(key, plainText, false, initVector,
				if segmentSize == nil then 1 else segmentSize)
			local iv = deepCopy(initVector)
			local b, k, p, q, s, t = {}, {}, initVector, {}, {{}, {}, {}, {}}, {}
			for i = 1, #plainText, segmentSize do
				table.move(plainText, i, i + segmentSize - 1, 1, k)
				table.move(xorBytes(q, encrypt(key, km, p, s, t), k), 1, segmentSize, i, b)
				for j = 16, segmentSize + 1, - 1 do
					table.insert(q, 1, p[j])
				end
				table.move(q, 1, 16, 1, p)
			end

			return b, iv
		end,
		decrypt_CFB = function(key : bytes, cipherText : bytes, initVector : bytes, segmentSize : number?)
			: bytes
			local km
			key, cipherText, km, initVector, segmentSize = init(key, cipherText, false, initVector,
				if segmentSize == nil then 1 else segmentSize)

			local b, k, p, q, s, t = {}, {}, initVector, {}, {{}, {}, {}, {}}, {}
			for i = 1, #cipherText, segmentSize do
				table.move(cipherText, i, i + segmentSize - 1, 1, k)
				table.move(xorBytes(q, encrypt(key, km, p, s, t), k), 1, segmentSize, i, b)
				for j = 16, segmentSize + 1, - 1 do
					table.insert(k, 1, p[j])
				end
				table.move(k, 1, 16, 1, p)
			end

			return b
		end,
		-- Output feedback (OFB)
		encrypt_OFB = function(key : bytes, plainText : bytes, initVector : bytes?) 			: bytes
			local km
			key, plainText, km, initVector = init(key, plainText, false, initVector)
			local iv = deepCopy(initVector)
			local b, k, p, s, t = {}, {}, initVector, {{}, {}, {}, {}}, {}
			for i = 1, #plainText, 16 do
				table.move(plainText, i, i + 15, 1, k)
				table.move(encrypt(key, km, p, s, t), 1, 16, 1, p)
				table.move(xorBytes(t, k, p), 1, 16, i, b)
			end

			return b, iv
		end,
		-- Counter (CTR)
		encrypt_CTR = function(key : bytes, plainText : bytes, counter : ((bytes) -> bytes) | bytes | { [
			string]: any }?) : bytes
			local km
			key, plainText, km, counter = init(key, plainText, true, counter)
			local iv = deepCopy(counter)
			local b, k, c, s, t, r, n = {}, {}, {}, {{}, {}, {}, {}}, {}, type(counter) == "table", nil
			for i = 1, #plainText, 16 do
				if r then
					if i > 1 and incBytes(counter.InitValue, counter.LittleEndian) then
						table.move(counter.InitOverflow, 1, 16, 1, counter.InitValue)
					end
					table.clear	(c)
					table.move	(counter.Prefix, 1, #counter.Prefix, 1, c)
					table.move	(counter.InitValue, 1, counter.Length, #c + 1, c)
					table.move	(counter.Suffix, 1, #counter.Suffix, #c + 1, c)
				else
					n = convertType(counter(c, (i + 15) / 16))
					assert		(#n == 16, "Counter must be 16 bytes long")
					table.move	(n, 1, 16, 1, c)
				end
				table.move(plainText, i, i + 15, 1, k)
				table.move(xorBytes(c, encrypt(key, km, c, s, t), k), 1, 16, i, b)
			end

			return b, iv
		end
	} -- Returns the library
end)()
local base64 = (function()
	--!native
	--!optimize 2
	-- Credits @Reselim

	local lookupValueToCharacter = buffer.create(64)
	local lookupCharacterToValue = buffer.create(256)

	local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local padding = string.byte("=")

	for index = 1, 64 do
		local value = index - 1
		local character = string.byte(alphabet, index)

		buffer.writeu8(lookupValueToCharacter, value, character)
		buffer.writeu8(lookupCharacterToValue, character, value)
	end

	local function encode(input: buffer): buffer
		local inputLength = buffer.len(input)
		local inputChunks = math.ceil(inputLength / 3)

		local outputLength = inputChunks * 4
		local output = buffer.create(outputLength)

		-- Since we use readu32 and chunks are 3 bytes large, we can't read the last chunk here
		for chunkIndex = 1, inputChunks - 1 do
			local inputIndex = (chunkIndex - 1) * 3
			local outputIndex = (chunkIndex - 1) * 4

			local chunk = bit32.byteswap(buffer.readu32(input, inputIndex))

			-- 8 + 24 - (6 * index)
			local value1 = bit32.rshift(chunk, 26)
			local value2 = bit32.band(bit32.rshift(chunk, 20), 0b111111)
			local value3 = bit32.band(bit32.rshift(chunk, 14), 0b111111)
			local value4 = bit32.band(bit32.rshift(chunk, 8), 0b111111)

			buffer.writeu8(output, outputIndex, buffer.readu8(lookupValueToCharacter, value1))
			buffer.writeu8(output, outputIndex + 1, buffer.readu8(lookupValueToCharacter, value2))
			buffer.writeu8(output, outputIndex + 2, buffer.readu8(lookupValueToCharacter, value3))
			buffer.writeu8(output, outputIndex + 3, buffer.readu8(lookupValueToCharacter, value4))
		end

		local inputRemainder = inputLength % 3

		if inputRemainder == 1 then
			local chunk = buffer.readu8(input, inputLength - 1)

			local value1 = bit32.rshift(chunk, 2)
			local value2 = bit32.band(bit32.lshift(chunk, 4), 0b111111)

			buffer.writeu8(output, outputLength - 4, buffer.readu8(lookupValueToCharacter, value1))
			buffer.writeu8(output, outputLength - 3, buffer.readu8(lookupValueToCharacter, value2))
			buffer.writeu8(output, outputLength - 2, padding)
			buffer.writeu8(output, outputLength - 1, padding)
		elseif inputRemainder == 2 then
			local chunk = bit32.bor(
				bit32.lshift(buffer.readu8(input, inputLength - 2), 8),
				buffer.readu8(input, inputLength - 1)
			)

			local value1 = bit32.rshift(chunk, 10)
			local value2 = bit32.band(bit32.rshift(chunk, 4), 0b111111)
			local value3 = bit32.band(bit32.lshift(chunk, 2), 0b111111)

			buffer.writeu8(output, outputLength - 4, buffer.readu8(lookupValueToCharacter, value1))
			buffer.writeu8(output, outputLength - 3, buffer.readu8(lookupValueToCharacter, value2))
			buffer.writeu8(output, outputLength - 2, buffer.readu8(lookupValueToCharacter, value3))
			buffer.writeu8(output, outputLength - 1, padding)
		elseif inputRemainder == 0 and inputLength ~= 0 then
			local chunk = bit32.bor(
				bit32.lshift(buffer.readu8(input, inputLength - 3), 16),
				bit32.lshift(buffer.readu8(input, inputLength - 2), 8),
				buffer.readu8(input, inputLength - 1)
			)

			local value1 = bit32.rshift(chunk, 18)
			local value2 = bit32.band(bit32.rshift(chunk, 12), 0b111111)
			local value3 = bit32.band(bit32.rshift(chunk, 6), 0b111111)
			local value4 = bit32.band(chunk, 0b111111)

			buffer.writeu8(output, outputLength - 4, buffer.readu8(lookupValueToCharacter, value1))
			buffer.writeu8(output, outputLength - 3, buffer.readu8(lookupValueToCharacter, value2))
			buffer.writeu8(output, outputLength - 2, buffer.readu8(lookupValueToCharacter, value3))
			buffer.writeu8(output, outputLength - 1, buffer.readu8(lookupValueToCharacter, value4))
		end

		return output
	end

	local function decode(input: buffer): buffer
		local inputLength = buffer.len(input)
		local inputChunks = math.ceil(inputLength / 4)

		-- TODO: Support input without padding
		local inputPadding = 0
		if inputLength ~= 0 then
			if buffer.readu8(input, inputLength - 1) == padding then inputPadding += 1 end
			if buffer.readu8(input, inputLength - 2) == padding then inputPadding += 1 end
		end

		local outputLength = inputChunks * 3 - inputPadding
		local output = buffer.create(outputLength)

		for chunkIndex = 1, inputChunks - 1 do
			local inputIndex = (chunkIndex - 1) * 4
			local outputIndex = (chunkIndex - 1) * 3

			local value1 = buffer.readu8(lookupCharacterToValue, buffer.readu8(input, inputIndex))
			local value2 = buffer.readu8(lookupCharacterToValue, buffer.readu8(input, inputIndex + 1))
			local value3 = buffer.readu8(lookupCharacterToValue, buffer.readu8(input, inputIndex + 2))
			local value4 = buffer.readu8(lookupCharacterToValue, buffer.readu8(input, inputIndex + 3))

			local chunk = bit32.bor(
				bit32.lshift(value1, 18),
				bit32.lshift(value2, 12),
				bit32.lshift(value3, 6),
				value4
			)

			local character1 = bit32.rshift(chunk, 16)
			local character2 = bit32.band(bit32.rshift(chunk, 8), 0b11111111)
			local character3 = bit32.band(chunk, 0b11111111)

			buffer.writeu8(output, outputIndex, character1)
			buffer.writeu8(output, outputIndex + 1, character2)
			buffer.writeu8(output, outputIndex + 2, character3)
		end

		if inputLength ~= 0 then
			local lastInputIndex = (inputChunks - 1) * 4
			local lastOutputIndex = (inputChunks - 1) * 3

			local lastValue1 = buffer.readu8(lookupCharacterToValue, buffer.readu8(input, lastInputIndex))
			local lastValue2 = buffer.readu8(lookupCharacterToValue, buffer.readu8(input, lastInputIndex + 1))
			local lastValue3 = buffer.readu8(lookupCharacterToValue, buffer.readu8(input, lastInputIndex + 2))
			local lastValue4 = buffer.readu8(lookupCharacterToValue, buffer.readu8(input, lastInputIndex + 3))

			local lastChunk = bit32.bor(
				bit32.lshift(lastValue1, 18),
				bit32.lshift(lastValue2, 12),
				bit32.lshift(lastValue3, 6),
				lastValue4
			)

			if inputPadding <= 2 then
				local lastCharacter1 = bit32.rshift(lastChunk, 16)
				buffer.writeu8(output, lastOutputIndex, lastCharacter1)

				if inputPadding <= 1 then
					local lastCharacter2 = bit32.band(bit32.rshift(lastChunk, 8), 0b11111111)
					buffer.writeu8(output, lastOutputIndex + 1, lastCharacter2)

					if inputPadding == 0 then
						local lastCharacter3 = bit32.band(lastChunk, 0b11111111)
						buffer.writeu8(output, lastOutputIndex + 2, lastCharacter3)
					end
				end
			end
		end

		return output
	end

	return {
		encode = encode,
		decode = decode,
	}
end)()
local goodsignal = (function()
	--------------------------------------------------------------------------------
	--               Batched Yield-Safe Signal Implementation                     --
	-- This is a Signal class which has effectively identical behavior to a       --
	-- normal RBXScriptSignal, with the only difference being a couple extra      --
	-- stack frames at the bottom of the stack trace when an error is thrown.     --
	-- This implementation caches runner coroutines, so the ability to yield in   --
	-- the signal handlers comes at minimal extra cost over a naive signal        --
	-- implementation that either always or never spawns a thread.                --
	--                                                                            --
	-- API:                                                                       --
	--   local Signal = require(THIS MODULE)                                      --
	--   local sig = Signal.new()                                                 --
	--   local connection = sig:Connect(function(arg1, arg2, ...) ... end)        --
	--   sig:Fire(arg1, arg2, ...)                                                --
	--   connection:Disconnect()                                                  --
	--   sig:DisconnectAll()                                                      --
	--   local arg1, arg2, ... = sig:Wait()                                       --
	--                                                                            --
	-- Licence:                                                                   --
	--   Licenced under the MIT licence.                                          --
	--                                                                            --
	-- Authors:                                                                   --
	--   stravant - July 31st, 2021 - Created the file.                           --
	--------------------------------------------------------------------------------

	-- The currently idle thread to run the next handler on
	local freeRunnerThread = nil

	-- Function which acquires the currently idle handler runner thread, runs the
	-- function fn on it, and then releases the thread, returning it to being the
	-- currently idle one.
	-- If there was a currently idle runner thread already, that's okay, that old
	-- one will just get thrown and eventually GCed.
	local function acquireRunnerThreadAndCallEventHandler(fn, ...)
		local acquiredRunnerThread = freeRunnerThread
		freeRunnerThread = nil
		fn(...)
		-- The handler finished running, this runner thread is free again.
		freeRunnerThread = acquiredRunnerThread
	end

	-- Coroutine runner that we create coroutines of. The coroutine can be 
	-- repeatedly resumed with functions to run followed by the argument to run
	-- them with.
	local function runEventHandlerInFreeThread()
		-- Note: We cannot use the initial set of arguments passed to
		-- runEventHandlerInFreeThread for a call to the handler, because those
		-- arguments would stay on the stack for the duration of the thread's
		-- existence, temporarily leaking references. Without access to raw bytecode
		-- there's no way for us to clear the "..." references from the stack.
		while true do
			acquireRunnerThreadAndCallEventHandler(coroutine.yield())
		end
	end

	-- Connection class
	local Connection = {}
	Connection.__index = Connection

	function Connection.new(signal, fn)
		return setmetatable({
			_connected = true,
			_signal = signal,
			_fn = fn,
			_next = false,
		}, Connection)
	end

	function Connection:Disconnect()
		self._connected = false

		-- Unhook the node, but DON'T clear it. That way any fire calls that are
		-- currently sitting on this node will be able to iterate forwards off of
		-- it, but any subsequent fire calls will not hit it, and it will be GCed
		-- when no more fire calls are sitting on it.
		if self._signal._handlerListHead == self then
			self._signal._handlerListHead = self._next
		else
			local prev = self._signal._handlerListHead
			while prev and prev._next ~= self do
				prev = prev._next
			end
			if prev then
				prev._next = self._next
			end
		end
	end

	-- Make Connection strict
	setmetatable(Connection, {
		__index = function(tb, key)
			error(("Attempt to get Connection::%s (not a valid member)"):format(tostring(key)), 2)
		end,
		__newindex = function(tb, key, value)
			error(("Attempt to set Connection::%s (not a valid member)"):format(tostring(key)), 2)
		end
	})

	-- Signal class
	local Signal = {}
	Signal.__index = Signal

	function Signal.new()
		return setmetatable({
			_handlerListHead = false,
		}, Signal)
	end

	function Signal:Connect(fn)
		local connection = Connection.new(self, fn)
		if self._handlerListHead then
			connection._next = self._handlerListHead
			self._handlerListHead = connection
		else
			self._handlerListHead = connection
		end
		return connection
	end

	-- Disconnect all handlers. Since we use a linked list it suffices to clear the
	-- reference to the head handler.
	function Signal:DisconnectAll()
		self._handlerListHead = false
	end

	-- Signal:Fire(...) implemented by running the handler functions on the
	-- coRunnerThread, and any time the resulting thread yielded without returning
	-- to us, that means that it yielded to the Roblox scheduler and has been taken
	-- over by Roblox scheduling, meaning we have to make a new coroutine runner.
	function Signal:Fire(...)
		local item = self._handlerListHead
		while item do
			if item._connected then
				if not freeRunnerThread then
					freeRunnerThread = coroutine.create(runEventHandlerInFreeThread)
					-- Get the freeRunnerThread to the first yield
					coroutine.resume(freeRunnerThread)
				end
				task.spawn(freeRunnerThread, item._fn, ...)
			end
			item = item._next
		end
	end

	-- Implement Signal:Wait() in terms of a temporary connection using
	-- a Signal:Connect() which disconnects itself.
	function Signal:Wait()
		local waitingCoroutine = coroutine.running()
		local cn;
		cn = self:Connect(function(...)
			cn:Disconnect()
			task.spawn(waitingCoroutine, ...)
		end)
		return coroutine.yield()
	end

	-- Implement Signal:Once() in terms of a connection which disconnects
	-- itself before running the handler.
	function Signal:Once(fn)
		local cn;
		cn = self:Connect(function(...)
			if cn._connected then
				cn:Disconnect()
			end
			fn(...)
		end)
		return cn
	end

	-- Make signal strict
	setmetatable(Signal, {
		__index = function(tb, key)
			error(("Attempt to get Signal::%s (not a valid member)"):format(tostring(key)), 2)
		end,
		__newindex = function(tb, key, value)
			error(("Attempt to set Signal::%s (not a valid member)"):format(tostring(key)), 2)
		end
	})

	return Signal
end)()
local hashlib = (function()
	--!native
--[=[------------------------------------------------------------------------------------------------------------------------
-- HashLib by Egor Skriptunoff, boatbomber, and howmanysmall

Documentation here: https://devforum.roblox.com/t/open-source-hashlib/416732/1

--------------------------------------------------------------------------------------------------------------------------

Module was originally written by Egor Skriptunoff and distributed under an MIT license.
It can be found here: https://github.com/Egor-Skriptunoff/pure_lua_SHA/blob/master/sha2.lua

That version was around 3000 lines long, and supported Lua versions 5.1, 5.2, 5.3, and 5.4, and LuaJIT.
Although that is super cool, Roblox only uses Lua 5.1, so that was extreme overkill.

I, boatbomber, worked to port it to Roblox in a way that doesn't overcomplicate it with support of unreachable
cases. Then, howmanysmall did some final optimizations that really squeeze out all the performance possible.
It's gotten stupid fast, thanks to her!

After quite a bit of work and benchmarking, this is what we were left with.
Enjoy!

--------------------------------------------------------------------------------------------------------------------------

DESCRIPTION:
	This module contains functions to calculate SHA digest:
		MD5, SHA-1,
		SHA-224, SHA-256, SHA-512/224, SHA-512/256, SHA-384, SHA-512,
		SHA3-224, SHA3-256, SHA3-384, SHA3-512, SHAKE128, SHAKE256,
		HMAC
	Additionally, it has a few extra utility functions:
		hex_to_bin
		base64_to_bin
		bin_to_base64
	Written in pure Lua.
USAGE:
	Input data should be a string
	Result (SHA digest) is returned in hexadecimal representation as a string of lowercase hex digits.
	Simplest usage example:
		local HashLib = require(script.HashLib)
		local your_hash = HashLib.sha256("your string")
API:
		HashLib.md5
		HashLib.sha1
	SHA2 hash functions:
		HashLib.sha224
		HashLib.sha256
		HashLib.sha512_224
		HashLib.sha512_256
		HashLib.sha384
		HashLib.sha512
	SHA3 hash functions:
		HashLib.sha3_224
		HashLib.sha3_256
		HashLib.sha3_384
		HashLib.sha3_512
		HashLib.shake128
		HashLib.shake256
	Misc utilities:
		HashLib.hmac (Applicable to any hash function from this module except SHAKE*)
		HashLib.hex_to_bin
		HashLib.base64_to_bin
		HashLib.bin_to_base64

--]=]---------------------------------------------------------------------------

	-- local Base64 = require(script.Base64)

	--------------------------------------------------------------------------------
	-- LOCALIZATION FOR VM OPTIMIZATIONS
	--------------------------------------------------------------------------------



	--------------------------------------------------------------------------------
	-- 32-BIT BITWISE FUNCTIONS
	--------------------------------------------------------------------------------
	-- Only low 32 bits of function arguments matter, high bits are ignored
	-- The result of all functions (except HEX) is an integer inside "correct range":
	-- for "bit" library:    (-TWO_POW_31)..(TWO_POW_31-1)
	-- for "bit32" library:        0..(TWO_POW_32-1)
	local bit32_band = bit32.band -- 2 arguments
	local bit32_bor = bit32.bor -- 2 arguments
	local bit32_bxor = bit32.bxor -- 2..5 arguments
	local bit32_lshift = bit32.lshift -- second argument is integer 0..31
	local bit32_rshift = bit32.rshift -- second argument is integer 0..31
	local bit32_lrotate = bit32.lrotate -- second argument is integer 0..31
	local bit32_rrotate = bit32.rrotate -- second argument is integer 0..31

	--------------------------------------------------------------------------------
	-- CREATING OPTIMIZED INNER LOOP
	--------------------------------------------------------------------------------
	-- Arrays of SHA2 "magic numbers" (in "INT64" and "FFI" branches "*_lo" arrays contain 64-bit values)
	local sha2_K_lo, sha2_K_hi, sha2_H_lo, sha2_H_hi, sha3_RC_lo, sha3_RC_hi = {}, {}, {}, {}, {}, {}
	local sha2_H_ext256 = {
		[224] = {};
		[256] = sha2_H_hi;
	}

	local sha2_H_ext512_lo, sha2_H_ext512_hi = {
		[384] = {};
		[512] = sha2_H_lo;
	}, {
		[384] = {};
		[512] = sha2_H_hi;
	}

	local md5_K, md5_sha1_H = {}, {0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0}
	local md5_next_shift = {0, 0, 0, 0, 0, 0, 0, 0, 28, 25, 26, 27, 0, 0, 10, 9, 11, 12, 0, 15, 16, 17, 18, 0, 20, 22, 23, 21}
	local HEX64, XOR64A5, lanes_index_base -- defined only for branches that internally use 64-bit integers: "INT64" and "FFI"
	local common_W = {} -- temporary table shared between all calculations (to avoid creating new temporary table every time)
	local K_lo_modulo, hi_factor, hi_factor_keccak = 4294967296, 0, 0

	local TWO_POW_NEG_56 = 2 ^ -56
	local TWO_POW_NEG_17 = 2 ^ -17

	local TWO_POW_2 = 2 ^ 2
	local TWO_POW_3 = 2 ^ 3
	local TWO_POW_4 = 2 ^ 4
	local TWO_POW_5 = 2 ^ 5
	local TWO_POW_6 = 2 ^ 6
	local TWO_POW_7 = 2 ^ 7
	local TWO_POW_8 = 2 ^ 8
	local TWO_POW_9 = 2 ^ 9
	local TWO_POW_10 = 2 ^ 10
	local TWO_POW_11 = 2 ^ 11
	local TWO_POW_12 = 2 ^ 12
	local TWO_POW_13 = 2 ^ 13
	local TWO_POW_14 = 2 ^ 14
	local TWO_POW_15 = 2 ^ 15
	local TWO_POW_16 = 2 ^ 16
	local TWO_POW_17 = 2 ^ 17
	local TWO_POW_18 = 2 ^ 18
	local TWO_POW_19 = 2 ^ 19
	local TWO_POW_20 = 2 ^ 20
	local TWO_POW_21 = 2 ^ 21
	local TWO_POW_22 = 2 ^ 22
	local TWO_POW_23 = 2 ^ 23
	local TWO_POW_24 = 2 ^ 24
	local TWO_POW_25 = 2 ^ 25
	local TWO_POW_26 = 2 ^ 26
	local TWO_POW_27 = 2 ^ 27
	local TWO_POW_28 = 2 ^ 28
	local TWO_POW_29 = 2 ^ 29
	local TWO_POW_30 = 2 ^ 30
	local TWO_POW_31 = 2 ^ 31
	local TWO_POW_32 = 2 ^ 32
	local TWO_POW_40 = 2 ^ 40

	local TWO56_POW_7 = 256 ^ 7

	-- Implementation for Lua 5.1/5.2 (with or without bitwise library available)
	local function sha256_feed_64(H, str, offs, size)
		-- offs >= 0, size >= 0, size is multiple of 64
		local W, K = common_W, sha2_K_hi
		local h1, h2, h3, h4, h5, h6, h7, h8 = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
		for pos = offs, offs + size - 1, 64 do
			for j = 1, 16 do
				pos = pos + 4
				local a, b, c, d = string.byte(str, pos - 3, pos)
				W[j] = ((a * 256 + b) * 256 + c) * 256 + d
			end

			for j = 17, 64 do
				local a, b = W[j - 15], W[j - 2]
				W[j] = bit32_bxor(bit32_rrotate(a, 7), bit32_lrotate(a, 14), bit32_rshift(a, 3)) + bit32_bxor(bit32_lrotate(b, 15), bit32_lrotate(b, 13), bit32_rshift(b, 10)) + W[j - 7] + W[j - 16]
			end

			local a, b, c, d, e, f, g, h = h1, h2, h3, h4, h5, h6, h7, h8
			for j = 1, 64 do
				local z = bit32_bxor(bit32_rrotate(e, 6), bit32_rrotate(e, 11), bit32_lrotate(e, 7)) + bit32_band(e, f) + bit32_band(-1 - e, g) + h + K[j] + W[j]
				h = g
				g = f
				f = e
				e = z + d
				d = c
				c = b
				b = a
				a = z + bit32_band(d, c) + bit32_band(a, bit32_bxor(d, c)) + bit32_bxor(bit32_rrotate(a, 2), bit32_rrotate(a, 13), bit32_lrotate(a, 10))
			end

			h1, h2, h3, h4 = (a + h1) % 4294967296, (b + h2) % 4294967296, (c + h3) % 4294967296, (d + h4) % 4294967296
			h5, h6, h7, h8 = (e + h5) % 4294967296, (f + h6) % 4294967296, (g + h7) % 4294967296, (h + h8) % 4294967296
		end

		H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8] = h1, h2, h3, h4, h5, h6, h7, h8
	end

	local function sha512_feed_128(H_lo, H_hi, str, offs, size)
		-- offs >= 0, size >= 0, size is multiple of 128
		-- W1_hi, W1_lo, W2_hi, W2_lo, ...   Wk_hi = W[2*k-1], Wk_lo = W[2*k]
		local W, K_lo, K_hi = common_W, sha2_K_lo, sha2_K_hi
		local h1_lo, h2_lo, h3_lo, h4_lo, h5_lo, h6_lo, h7_lo, h8_lo = H_lo[1], H_lo[2], H_lo[3], H_lo[4], H_lo[5], H_lo[6], H_lo[7], H_lo[8]
		local h1_hi, h2_hi, h3_hi, h4_hi, h5_hi, h6_hi, h7_hi, h8_hi = H_hi[1], H_hi[2], H_hi[3], H_hi[4], H_hi[5], H_hi[6], H_hi[7], H_hi[8]
		for pos = offs, offs + size - 1, 128 do
			for j = 1, 16 * 2 do
				pos = pos + 4
				local a, b, c, d = string.byte(str, pos - 3, pos)
				W[j] = ((a * 256 + b) * 256 + c) * 256 + d
			end

			for jj = 34, 160, 2 do
				local a_lo, a_hi, b_lo, b_hi = W[jj - 30], W[jj - 31], W[jj - 4], W[jj - 5]
				local tmp1 = bit32_bxor(bit32_rshift(a_lo, 1) + bit32_lshift(a_hi, 31), bit32_rshift(a_lo, 8) + bit32_lshift(a_hi, 24), bit32_rshift(a_lo, 7) + bit32_lshift(a_hi, 25)) % 4294967296 +
					bit32_bxor(bit32_rshift(b_lo, 19) + bit32_lshift(b_hi, 13), bit32_lshift(b_lo, 3) + bit32_rshift(b_hi, 29), bit32_rshift(b_lo, 6) + bit32_lshift(b_hi, 26)) % 4294967296 +
					W[jj - 14] + W[jj - 32]

				local tmp2 = tmp1 % 4294967296
				W[jj - 1] = bit32_bxor(bit32_rshift(a_hi, 1) + bit32_lshift(a_lo, 31), bit32_rshift(a_hi, 8) + bit32_lshift(a_lo, 24), bit32_rshift(a_hi, 7)) +
					bit32_bxor(bit32_rshift(b_hi, 19) + bit32_lshift(b_lo, 13), bit32_lshift(b_hi, 3) + bit32_rshift(b_lo, 29), bit32_rshift(b_hi, 6)) +
					W[jj - 15] + W[jj - 33] + (tmp1 - tmp2) / 4294967296

				W[jj] = tmp2
			end

			local a_lo, b_lo, c_lo, d_lo, e_lo, f_lo, g_lo, h_lo = h1_lo, h2_lo, h3_lo, h4_lo, h5_lo, h6_lo, h7_lo, h8_lo
			local a_hi, b_hi, c_hi, d_hi, e_hi, f_hi, g_hi, h_hi = h1_hi, h2_hi, h3_hi, h4_hi, h5_hi, h6_hi, h7_hi, h8_hi
			for j = 1, 80 do
				local jj = 2 * j
				local tmp1 = bit32_bxor(bit32_rshift(e_lo, 14) + bit32_lshift(e_hi, 18), bit32_rshift(e_lo, 18) + bit32_lshift(e_hi, 14), bit32_lshift(e_lo, 23) + bit32_rshift(e_hi, 9)) % 4294967296 +
					(bit32_band(e_lo, f_lo) + bit32_band(-1 - e_lo, g_lo)) % 4294967296 +
					h_lo + K_lo[j] + W[jj]

				local z_lo = tmp1 % 4294967296
				local z_hi = bit32_bxor(bit32_rshift(e_hi, 14) + bit32_lshift(e_lo, 18), bit32_rshift(e_hi, 18) + bit32_lshift(e_lo, 14), bit32_lshift(e_hi, 23) + bit32_rshift(e_lo, 9)) +
					bit32_band(e_hi, f_hi) + bit32_band(-1 - e_hi, g_hi) +
					h_hi + K_hi[j] + W[jj - 1] +
					(tmp1 - z_lo) / 4294967296

				h_lo = g_lo
				h_hi = g_hi
				g_lo = f_lo
				g_hi = f_hi
				f_lo = e_lo
				f_hi = e_hi
				tmp1 = z_lo + d_lo
				e_lo = tmp1 % 4294967296
				e_hi = z_hi + d_hi + (tmp1 - e_lo) / 4294967296
				d_lo = c_lo
				d_hi = c_hi
				c_lo = b_lo
				c_hi = b_hi
				b_lo = a_lo
				b_hi = a_hi
				tmp1 = z_lo + (bit32_band(d_lo, c_lo) + bit32_band(b_lo, bit32_bxor(d_lo, c_lo))) % 4294967296 + bit32_bxor(bit32_rshift(b_lo, 28) + bit32_lshift(b_hi, 4), bit32_lshift(b_lo, 30) + bit32_rshift(b_hi, 2), bit32_lshift(b_lo, 25) + bit32_rshift(b_hi, 7)) % 4294967296
				a_lo = tmp1 % 4294967296
				a_hi = z_hi + (bit32_band(d_hi, c_hi) + bit32_band(b_hi, bit32_bxor(d_hi, c_hi))) + bit32_bxor(bit32_rshift(b_hi, 28) + bit32_lshift(b_lo, 4), bit32_lshift(b_hi, 30) + bit32_rshift(b_lo, 2), bit32_lshift(b_hi, 25) + bit32_rshift(b_lo, 7)) + (tmp1 - a_lo) / 4294967296
			end

			a_lo = h1_lo + a_lo
			h1_lo = a_lo % 4294967296
			h1_hi = (h1_hi + a_hi + (a_lo - h1_lo) / 4294967296) % 4294967296
			a_lo = h2_lo + b_lo
			h2_lo = a_lo % 4294967296
			h2_hi = (h2_hi + b_hi + (a_lo - h2_lo) / 4294967296) % 4294967296
			a_lo = h3_lo + c_lo
			h3_lo = a_lo % 4294967296
			h3_hi = (h3_hi + c_hi + (a_lo - h3_lo) / 4294967296) % 4294967296
			a_lo = h4_lo + d_lo
			h4_lo = a_lo % 4294967296
			h4_hi = (h4_hi + d_hi + (a_lo - h4_lo) / 4294967296) % 4294967296
			a_lo = h5_lo + e_lo
			h5_lo = a_lo % 4294967296
			h5_hi = (h5_hi + e_hi + (a_lo - h5_lo) / 4294967296) % 4294967296
			a_lo = h6_lo + f_lo
			h6_lo = a_lo % 4294967296
			h6_hi = (h6_hi + f_hi + (a_lo - h6_lo) / 4294967296) % 4294967296
			a_lo = h7_lo + g_lo
			h7_lo = a_lo % 4294967296
			h7_hi = (h7_hi + g_hi + (a_lo - h7_lo) / 4294967296) % 4294967296
			a_lo = h8_lo + h_lo
			h8_lo = a_lo % 4294967296
			h8_hi = (h8_hi + h_hi + (a_lo - h8_lo) / 4294967296) % 4294967296
		end

		H_lo[1], H_lo[2], H_lo[3], H_lo[4], H_lo[5], H_lo[6], H_lo[7], H_lo[8] = h1_lo, h2_lo, h3_lo, h4_lo, h5_lo, h6_lo, h7_lo, h8_lo
		H_hi[1], H_hi[2], H_hi[3], H_hi[4], H_hi[5], H_hi[6], H_hi[7], H_hi[8] = h1_hi, h2_hi, h3_hi, h4_hi, h5_hi, h6_hi, h7_hi, h8_hi
	end

	local function md5_feed_64(H, str, offs, size)
		-- offs >= 0, size >= 0, size is multiple of 64
		local W, K, md5_next_shift = common_W, md5_K, md5_next_shift
		local h1, h2, h3, h4 = H[1], H[2], H[3], H[4]
		for pos = offs, offs + size - 1, 64 do
			for j = 1, 16 do
				pos = pos + 4
				local a, b, c, d = string.byte(str, pos - 3, pos)
				W[j] = ((d * 256 + c) * 256 + b) * 256 + a
			end

			local a, b, c, d = h1, h2, h3, h4
			local s = 25
			for j = 1, 16 do
				local F = bit32_rrotate(bit32_band(b, c) + bit32_band(-1 - b, d) + a + K[j] + W[j], s) + b
				s = md5_next_shift[s]
				a = d
				d = c
				c = b
				b = F
			end

			s = 27
			for j = 17, 32 do
				local F = bit32_rrotate(bit32_band(d, b) + bit32_band(-1 - d, c) + a + K[j] + W[(5 * j - 4) % 16 + 1], s) + b
				s = md5_next_shift[s]
				a = d
				d = c
				c = b
				b = F
			end

			s = 28
			for j = 33, 48 do
				local F = bit32_rrotate(bit32_bxor(bit32_bxor(b, c), d) + a + K[j] + W[(3 * j + 2) % 16 + 1], s) + b
				s = md5_next_shift[s]
				a = d
				d = c
				c = b
				b = F
			end

			s = 26
			for j = 49, 64 do
				local F = bit32_rrotate(bit32_bxor(c, bit32_bor(b, -1 - d)) + a + K[j] + W[(j * 7 - 7) % 16 + 1], s) + b
				s = md5_next_shift[s]
				a = d
				d = c
				c = b
				b = F
			end

			h1 = (a + h1) % 4294967296
			h2 = (b + h2) % 4294967296
			h3 = (c + h3) % 4294967296
			h4 = (d + h4) % 4294967296
		end

		H[1], H[2], H[3], H[4] = h1, h2, h3, h4
	end

	local function sha1_feed_64(H, str, offs, size)
		-- offs >= 0, size >= 0, size is multiple of 64
		local W = common_W
		local h1, h2, h3, h4, h5 = H[1], H[2], H[3], H[4], H[5]
		for pos = offs, offs + size - 1, 64 do
			for j = 1, 16 do
				pos = pos + 4
				local a, b, c, d = string.byte(str, pos - 3, pos)
				W[j] = ((a * 256 + b) * 256 + c) * 256 + d
			end

			for j = 17, 80 do
				W[j] = bit32_lrotate(bit32_bxor(W[j - 3], W[j - 8], W[j - 14], W[j - 16]), 1)
			end

			local a, b, c, d, e = h1, h2, h3, h4, h5
			for j = 1, 20 do
				local z = bit32_lrotate(a, 5) + bit32_band(b, c) + bit32_band(-1 - b, d) + 0x5A827999 + W[j] + e -- constant = math.floor(TWO_POW_30 * sqrt(2))
				e = d
				d = c
				c = bit32_rrotate(b, 2)
				b = a
				a = z
			end

			for j = 21, 40 do
				local z = bit32_lrotate(a, 5) + bit32_bxor(b, c, d) + 0x6ED9EBA1 + W[j] + e -- TWO_POW_30 * sqrt(3)
				e = d
				d = c
				c = bit32_rrotate(b, 2)
				b = a
				a = z
			end

			for j = 41, 60 do
				local z = bit32_lrotate(a, 5) + bit32_band(d, c) + bit32_band(b, bit32_bxor(d, c)) + 0x8F1BBCDC + W[j] + e -- TWO_POW_30 * sqrt(5)
				e = d
				d = c
				c = bit32_rrotate(b, 2)
				b = a
				a = z
			end

			for j = 61, 80 do
				local z = bit32_lrotate(a, 5) + bit32_bxor(b, c, d) + 0xCA62C1D6 + W[j] + e -- TWO_POW_30 * sqrt(10)
				e = d
				d = c
				c = bit32_rrotate(b, 2)
				b = a
				a = z
			end

			h1 = (a + h1) % 4294967296
			h2 = (b + h2) % 4294967296
			h3 = (c + h3) % 4294967296
			h4 = (d + h4) % 4294967296
			h5 = (e + h5) % 4294967296
		end

		H[1], H[2], H[3], H[4], H[5] = h1, h2, h3, h4, h5
	end

	local function keccak_feed(lanes_lo, lanes_hi, str, offs, size, block_size_in_bytes)
		-- This is an example of a Lua function having 79 local variables :-)
		-- offs >= 0, size >= 0, size is multiple of block_size_in_bytes, block_size_in_bytes is positive multiple of 8
		local RC_lo, RC_hi = sha3_RC_lo, sha3_RC_hi
		local qwords_qty = block_size_in_bytes / 8
		for pos = offs, offs + size - 1, block_size_in_bytes do
			for j = 1, qwords_qty do
				local a, b, c, d = string.byte(str, pos + 1, pos + 4)
				lanes_lo[j] = bit32_bxor(lanes_lo[j], ((d * 256 + c) * 256 + b) * 256 + a)
				pos = pos + 8
				a, b, c, d = string.byte(str, pos - 3, pos)
				lanes_hi[j] = bit32_bxor(lanes_hi[j], ((d * 256 + c) * 256 + b) * 256 + a)
			end

			local L01_lo, L01_hi, L02_lo, L02_hi, L03_lo, L03_hi, L04_lo, L04_hi, L05_lo, L05_hi, L06_lo, L06_hi, L07_lo, L07_hi, L08_lo, L08_hi, L09_lo, L09_hi, L10_lo, L10_hi, L11_lo, L11_hi, L12_lo, L12_hi, L13_lo, L13_hi, L14_lo, L14_hi, L15_lo, L15_hi, L16_lo, L16_hi, L17_lo, L17_hi, L18_lo, L18_hi, L19_lo, L19_hi, L20_lo, L20_hi, L21_lo, L21_hi, L22_lo, L22_hi, L23_lo, L23_hi, L24_lo, L24_hi, L25_lo, L25_hi = lanes_lo[1], lanes_hi[1], lanes_lo[2], lanes_hi[2], lanes_lo[3], lanes_hi[3], lanes_lo[4], lanes_hi[4], lanes_lo[5], lanes_hi[5], lanes_lo[6], lanes_hi[6], lanes_lo[7], lanes_hi[7], lanes_lo[8], lanes_hi[8], lanes_lo[9], lanes_hi[9], lanes_lo[10], lanes_hi[10], lanes_lo[11], lanes_hi[11], lanes_lo[12], lanes_hi[12], lanes_lo[13], lanes_hi[13], lanes_lo[14], lanes_hi[14], lanes_lo[15], lanes_hi[15], lanes_lo[16], lanes_hi[16], lanes_lo[17], lanes_hi[17], lanes_lo[18], lanes_hi[18], lanes_lo[19], lanes_hi[19], lanes_lo[20], lanes_hi[20], lanes_lo[21], lanes_hi[21], lanes_lo[22], lanes_hi[22], lanes_lo[23], lanes_hi[23], lanes_lo[24], lanes_hi[24], lanes_lo[25], lanes_hi[25]

			for round_idx = 1, 24 do
				local C1_lo = bit32_bxor(L01_lo, L06_lo, L11_lo, L16_lo, L21_lo)
				local C1_hi = bit32_bxor(L01_hi, L06_hi, L11_hi, L16_hi, L21_hi)
				local C2_lo = bit32_bxor(L02_lo, L07_lo, L12_lo, L17_lo, L22_lo)
				local C2_hi = bit32_bxor(L02_hi, L07_hi, L12_hi, L17_hi, L22_hi)
				local C3_lo = bit32_bxor(L03_lo, L08_lo, L13_lo, L18_lo, L23_lo)
				local C3_hi = bit32_bxor(L03_hi, L08_hi, L13_hi, L18_hi, L23_hi)
				local C4_lo = bit32_bxor(L04_lo, L09_lo, L14_lo, L19_lo, L24_lo)
				local C4_hi = bit32_bxor(L04_hi, L09_hi, L14_hi, L19_hi, L24_hi)
				local C5_lo = bit32_bxor(L05_lo, L10_lo, L15_lo, L20_lo, L25_lo)
				local C5_hi = bit32_bxor(L05_hi, L10_hi, L15_hi, L20_hi, L25_hi)

				local D_lo = bit32_bxor(C1_lo, C3_lo * 2 + (C3_hi % TWO_POW_32 - C3_hi % TWO_POW_31) / TWO_POW_31)
				local D_hi = bit32_bxor(C1_hi, C3_hi * 2 + (C3_lo % TWO_POW_32 - C3_lo % TWO_POW_31) / TWO_POW_31)

				local T0_lo = bit32_bxor(D_lo, L02_lo)
				local T0_hi = bit32_bxor(D_hi, L02_hi)
				local T1_lo = bit32_bxor(D_lo, L07_lo)
				local T1_hi = bit32_bxor(D_hi, L07_hi)
				local T2_lo = bit32_bxor(D_lo, L12_lo)
				local T2_hi = bit32_bxor(D_hi, L12_hi)
				local T3_lo = bit32_bxor(D_lo, L17_lo)
				local T3_hi = bit32_bxor(D_hi, L17_hi)
				local T4_lo = bit32_bxor(D_lo, L22_lo)
				local T4_hi = bit32_bxor(D_hi, L22_hi)

				L02_lo = (T1_lo % TWO_POW_32 - T1_lo % TWO_POW_20) / TWO_POW_20 + T1_hi * TWO_POW_12
				L02_hi = (T1_hi % TWO_POW_32 - T1_hi % TWO_POW_20) / TWO_POW_20 + T1_lo * TWO_POW_12
				L07_lo = (T3_lo % TWO_POW_32 - T3_lo % TWO_POW_19) / TWO_POW_19 + T3_hi * TWO_POW_13
				L07_hi = (T3_hi % TWO_POW_32 - T3_hi % TWO_POW_19) / TWO_POW_19 + T3_lo * TWO_POW_13
				L12_lo = T0_lo * 2 + (T0_hi % TWO_POW_32 - T0_hi % TWO_POW_31) / TWO_POW_31
				L12_hi = T0_hi * 2 + (T0_lo % TWO_POW_32 - T0_lo % TWO_POW_31) / TWO_POW_31
				L17_lo = T2_lo * TWO_POW_10 + (T2_hi % TWO_POW_32 - T2_hi % TWO_POW_22) / TWO_POW_22
				L17_hi = T2_hi * TWO_POW_10 + (T2_lo % TWO_POW_32 - T2_lo % TWO_POW_22) / TWO_POW_22
				L22_lo = T4_lo * TWO_POW_2 + (T4_hi % TWO_POW_32 - T4_hi % TWO_POW_30) / TWO_POW_30
				L22_hi = T4_hi * TWO_POW_2 + (T4_lo % TWO_POW_32 - T4_lo % TWO_POW_30) / TWO_POW_30

				D_lo = bit32_bxor(C2_lo, C4_lo * 2 + (C4_hi % TWO_POW_32 - C4_hi % TWO_POW_31) / TWO_POW_31)
				D_hi = bit32_bxor(C2_hi, C4_hi * 2 + (C4_lo % TWO_POW_32 - C4_lo % TWO_POW_31) / TWO_POW_31)

				T0_lo = bit32_bxor(D_lo, L03_lo)
				T0_hi = bit32_bxor(D_hi, L03_hi)
				T1_lo = bit32_bxor(D_lo, L08_lo)
				T1_hi = bit32_bxor(D_hi, L08_hi)
				T2_lo = bit32_bxor(D_lo, L13_lo)
				T2_hi = bit32_bxor(D_hi, L13_hi)
				T3_lo = bit32_bxor(D_lo, L18_lo)
				T3_hi = bit32_bxor(D_hi, L18_hi)
				T4_lo = bit32_bxor(D_lo, L23_lo)
				T4_hi = bit32_bxor(D_hi, L23_hi)

				L03_lo = (T2_lo % TWO_POW_32 - T2_lo % TWO_POW_21) / TWO_POW_21 + T2_hi * TWO_POW_11
				L03_hi = (T2_hi % TWO_POW_32 - T2_hi % TWO_POW_21) / TWO_POW_21 + T2_lo * TWO_POW_11
				L08_lo = (T4_lo % TWO_POW_32 - T4_lo % TWO_POW_3) / TWO_POW_3 + T4_hi * TWO_POW_29 % TWO_POW_32
				L08_hi = (T4_hi % TWO_POW_32 - T4_hi % TWO_POW_3) / TWO_POW_3 + T4_lo * TWO_POW_29 % TWO_POW_32
				L13_lo = T1_lo * TWO_POW_6 + (T1_hi % TWO_POW_32 - T1_hi % TWO_POW_26) / TWO_POW_26
				L13_hi = T1_hi * TWO_POW_6 + (T1_lo % TWO_POW_32 - T1_lo % TWO_POW_26) / TWO_POW_26
				L18_lo = T3_lo * TWO_POW_15 + (T3_hi % TWO_POW_32 - T3_hi % TWO_POW_17) / TWO_POW_17
				L18_hi = T3_hi * TWO_POW_15 + (T3_lo % TWO_POW_32 - T3_lo % TWO_POW_17) / TWO_POW_17
				L23_lo = (T0_lo % TWO_POW_32 - T0_lo % TWO_POW_2) / TWO_POW_2 + T0_hi * TWO_POW_30 % TWO_POW_32
				L23_hi = (T0_hi % TWO_POW_32 - T0_hi % TWO_POW_2) / TWO_POW_2 + T0_lo * TWO_POW_30 % TWO_POW_32

				D_lo = bit32_bxor(C3_lo, C5_lo * 2 + (C5_hi % TWO_POW_32 - C5_hi % TWO_POW_31) / TWO_POW_31)
				D_hi = bit32_bxor(C3_hi, C5_hi * 2 + (C5_lo % TWO_POW_32 - C5_lo % TWO_POW_31) / TWO_POW_31)

				T0_lo = bit32_bxor(D_lo, L04_lo)
				T0_hi = bit32_bxor(D_hi, L04_hi)
				T1_lo = bit32_bxor(D_lo, L09_lo)
				T1_hi = bit32_bxor(D_hi, L09_hi)
				T2_lo = bit32_bxor(D_lo, L14_lo)
				T2_hi = bit32_bxor(D_hi, L14_hi)
				T3_lo = bit32_bxor(D_lo, L19_lo)
				T3_hi = bit32_bxor(D_hi, L19_hi)
				T4_lo = bit32_bxor(D_lo, L24_lo)
				T4_hi = bit32_bxor(D_hi, L24_hi)

				L04_lo = T3_lo * TWO_POW_21 % TWO_POW_32 + (T3_hi % TWO_POW_32 - T3_hi % TWO_POW_11) / TWO_POW_11
				L04_hi = T3_hi * TWO_POW_21 % TWO_POW_32 + (T3_lo % TWO_POW_32 - T3_lo % TWO_POW_11) / TWO_POW_11
				L09_lo = T0_lo * TWO_POW_28 % TWO_POW_32 + (T0_hi % TWO_POW_32 - T0_hi % TWO_POW_4) / TWO_POW_4
				L09_hi = T0_hi * TWO_POW_28 % TWO_POW_32 + (T0_lo % TWO_POW_32 - T0_lo % TWO_POW_4) / TWO_POW_4
				L14_lo = T2_lo * TWO_POW_25 % TWO_POW_32 + (T2_hi % TWO_POW_32 - T2_hi % TWO_POW_7) / TWO_POW_7
				L14_hi = T2_hi * TWO_POW_25 % TWO_POW_32 + (T2_lo % TWO_POW_32 - T2_lo % TWO_POW_7) / TWO_POW_7
				L19_lo = (T4_lo % TWO_POW_32 - T4_lo % TWO_POW_8) / TWO_POW_8 + T4_hi * TWO_POW_24 % TWO_POW_32
				L19_hi = (T4_hi % TWO_POW_32 - T4_hi % TWO_POW_8) / TWO_POW_8 + T4_lo * TWO_POW_24 % TWO_POW_32
				L24_lo = (T1_lo % TWO_POW_32 - T1_lo % TWO_POW_9) / TWO_POW_9 + T1_hi * TWO_POW_23 % TWO_POW_32
				L24_hi = (T1_hi % TWO_POW_32 - T1_hi % TWO_POW_9) / TWO_POW_9 + T1_lo * TWO_POW_23 % TWO_POW_32

				D_lo = bit32_bxor(C4_lo, C1_lo * 2 + (C1_hi % TWO_POW_32 - C1_hi % TWO_POW_31) / TWO_POW_31)
				D_hi = bit32_bxor(C4_hi, C1_hi * 2 + (C1_lo % TWO_POW_32 - C1_lo % TWO_POW_31) / TWO_POW_31)

				T0_lo = bit32_bxor(D_lo, L05_lo)
				T0_hi = bit32_bxor(D_hi, L05_hi)
				T1_lo = bit32_bxor(D_lo, L10_lo)
				T1_hi = bit32_bxor(D_hi, L10_hi)
				T2_lo = bit32_bxor(D_lo, L15_lo)
				T2_hi = bit32_bxor(D_hi, L15_hi)
				T3_lo = bit32_bxor(D_lo, L20_lo)
				T3_hi = bit32_bxor(D_hi, L20_hi)
				T4_lo = bit32_bxor(D_lo, L25_lo)
				T4_hi = bit32_bxor(D_hi, L25_hi)

				L05_lo = T4_lo * TWO_POW_14 + (T4_hi % TWO_POW_32 - T4_hi % TWO_POW_18) / TWO_POW_18
				L05_hi = T4_hi * TWO_POW_14 + (T4_lo % TWO_POW_32 - T4_lo % TWO_POW_18) / TWO_POW_18
				L10_lo = T1_lo * TWO_POW_20 % TWO_POW_32 + (T1_hi % TWO_POW_32 - T1_hi % TWO_POW_12) / TWO_POW_12
				L10_hi = T1_hi * TWO_POW_20 % TWO_POW_32 + (T1_lo % TWO_POW_32 - T1_lo % TWO_POW_12) / TWO_POW_12
				L15_lo = T3_lo * TWO_POW_8 + (T3_hi % TWO_POW_32 - T3_hi % TWO_POW_24) / TWO_POW_24
				L15_hi = T3_hi * TWO_POW_8 + (T3_lo % TWO_POW_32 - T3_lo % TWO_POW_24) / TWO_POW_24
				L20_lo = T0_lo * TWO_POW_27 % TWO_POW_32 + (T0_hi % TWO_POW_32 - T0_hi % TWO_POW_5) / TWO_POW_5
				L20_hi = T0_hi * TWO_POW_27 % TWO_POW_32 + (T0_lo % TWO_POW_32 - T0_lo % TWO_POW_5) / TWO_POW_5
				L25_lo = (T2_lo % TWO_POW_32 - T2_lo % TWO_POW_25) / TWO_POW_25 + T2_hi * TWO_POW_7
				L25_hi = (T2_hi % TWO_POW_32 - T2_hi % TWO_POW_25) / TWO_POW_25 + T2_lo * TWO_POW_7

				D_lo = bit32_bxor(C5_lo, C2_lo * 2 + (C2_hi % TWO_POW_32 - C2_hi % TWO_POW_31) / TWO_POW_31)
				D_hi = bit32_bxor(C5_hi, C2_hi * 2 + (C2_lo % TWO_POW_32 - C2_lo % TWO_POW_31) / TWO_POW_31)

				T1_lo = bit32_bxor(D_lo, L06_lo)
				T1_hi = bit32_bxor(D_hi, L06_hi)
				T2_lo = bit32_bxor(D_lo, L11_lo)
				T2_hi = bit32_bxor(D_hi, L11_hi)
				T3_lo = bit32_bxor(D_lo, L16_lo)
				T3_hi = bit32_bxor(D_hi, L16_hi)
				T4_lo = bit32_bxor(D_lo, L21_lo)
				T4_hi = bit32_bxor(D_hi, L21_hi)

				L06_lo = T2_lo * TWO_POW_3 + (T2_hi % TWO_POW_32 - T2_hi % TWO_POW_29) / TWO_POW_29
				L06_hi = T2_hi * TWO_POW_3 + (T2_lo % TWO_POW_32 - T2_lo % TWO_POW_29) / TWO_POW_29
				L11_lo = T4_lo * TWO_POW_18 + (T4_hi % TWO_POW_32 - T4_hi % TWO_POW_14) / TWO_POW_14
				L11_hi = T4_hi * TWO_POW_18 + (T4_lo % TWO_POW_32 - T4_lo % TWO_POW_14) / TWO_POW_14
				L16_lo = (T1_lo % TWO_POW_32 - T1_lo % TWO_POW_28) / TWO_POW_28 + T1_hi * TWO_POW_4
				L16_hi = (T1_hi % TWO_POW_32 - T1_hi % TWO_POW_28) / TWO_POW_28 + T1_lo * TWO_POW_4
				L21_lo = (T3_lo % TWO_POW_32 - T3_lo % TWO_POW_23) / TWO_POW_23 + T3_hi * TWO_POW_9
				L21_hi = (T3_hi % TWO_POW_32 - T3_hi % TWO_POW_23) / TWO_POW_23 + T3_lo * TWO_POW_9

				L01_lo = bit32_bxor(D_lo, L01_lo)
				L01_hi = bit32_bxor(D_hi, L01_hi)
				L01_lo, L02_lo, L03_lo, L04_lo, L05_lo = bit32_bxor(L01_lo, bit32_band(-1 - L02_lo, L03_lo)), bit32_bxor(L02_lo, bit32_band(-1 - L03_lo, L04_lo)), bit32_bxor(L03_lo, bit32_band(-1 - L04_lo, L05_lo)), bit32_bxor(L04_lo, bit32_band(-1 - L05_lo, L01_lo)), bit32_bxor(L05_lo, bit32_band(-1 - L01_lo, L02_lo))
				L01_hi, L02_hi, L03_hi, L04_hi, L05_hi = bit32_bxor(L01_hi, bit32_band(-1 - L02_hi, L03_hi)), bit32_bxor(L02_hi, bit32_band(-1 - L03_hi, L04_hi)), bit32_bxor(L03_hi, bit32_band(-1 - L04_hi, L05_hi)), bit32_bxor(L04_hi, bit32_band(-1 - L05_hi, L01_hi)), bit32_bxor(L05_hi, bit32_band(-1 - L01_hi, L02_hi))
				L06_lo, L07_lo, L08_lo, L09_lo, L10_lo = bit32_bxor(L09_lo, bit32_band(-1 - L10_lo, L06_lo)), bit32_bxor(L10_lo, bit32_band(-1 - L06_lo, L07_lo)), bit32_bxor(L06_lo, bit32_band(-1 - L07_lo, L08_lo)), bit32_bxor(L07_lo, bit32_band(-1 - L08_lo, L09_lo)), bit32_bxor(L08_lo, bit32_band(-1 - L09_lo, L10_lo))
				L06_hi, L07_hi, L08_hi, L09_hi, L10_hi = bit32_bxor(L09_hi, bit32_band(-1 - L10_hi, L06_hi)), bit32_bxor(L10_hi, bit32_band(-1 - L06_hi, L07_hi)), bit32_bxor(L06_hi, bit32_band(-1 - L07_hi, L08_hi)), bit32_bxor(L07_hi, bit32_band(-1 - L08_hi, L09_hi)), bit32_bxor(L08_hi, bit32_band(-1 - L09_hi, L10_hi))
				L11_lo, L12_lo, L13_lo, L14_lo, L15_lo = bit32_bxor(L12_lo, bit32_band(-1 - L13_lo, L14_lo)), bit32_bxor(L13_lo, bit32_band(-1 - L14_lo, L15_lo)), bit32_bxor(L14_lo, bit32_band(-1 - L15_lo, L11_lo)), bit32_bxor(L15_lo, bit32_band(-1 - L11_lo, L12_lo)), bit32_bxor(L11_lo, bit32_band(-1 - L12_lo, L13_lo))
				L11_hi, L12_hi, L13_hi, L14_hi, L15_hi = bit32_bxor(L12_hi, bit32_band(-1 - L13_hi, L14_hi)), bit32_bxor(L13_hi, bit32_band(-1 - L14_hi, L15_hi)), bit32_bxor(L14_hi, bit32_band(-1 - L15_hi, L11_hi)), bit32_bxor(L15_hi, bit32_band(-1 - L11_hi, L12_hi)), bit32_bxor(L11_hi, bit32_band(-1 - L12_hi, L13_hi))
				L16_lo, L17_lo, L18_lo, L19_lo, L20_lo = bit32_bxor(L20_lo, bit32_band(-1 - L16_lo, L17_lo)), bit32_bxor(L16_lo, bit32_band(-1 - L17_lo, L18_lo)), bit32_bxor(L17_lo, bit32_band(-1 - L18_lo, L19_lo)), bit32_bxor(L18_lo, bit32_band(-1 - L19_lo, L20_lo)), bit32_bxor(L19_lo, bit32_band(-1 - L20_lo, L16_lo))
				L16_hi, L17_hi, L18_hi, L19_hi, L20_hi = bit32_bxor(L20_hi, bit32_band(-1 - L16_hi, L17_hi)), bit32_bxor(L16_hi, bit32_band(-1 - L17_hi, L18_hi)), bit32_bxor(L17_hi, bit32_band(-1 - L18_hi, L19_hi)), bit32_bxor(L18_hi, bit32_band(-1 - L19_hi, L20_hi)), bit32_bxor(L19_hi, bit32_band(-1 - L20_hi, L16_hi))
				L21_lo, L22_lo, L23_lo, L24_lo, L25_lo = bit32_bxor(L23_lo, bit32_band(-1 - L24_lo, L25_lo)), bit32_bxor(L24_lo, bit32_band(-1 - L25_lo, L21_lo)), bit32_bxor(L25_lo, bit32_band(-1 - L21_lo, L22_lo)), bit32_bxor(L21_lo, bit32_band(-1 - L22_lo, L23_lo)), bit32_bxor(L22_lo, bit32_band(-1 - L23_lo, L24_lo))
				L21_hi, L22_hi, L23_hi, L24_hi, L25_hi = bit32_bxor(L23_hi, bit32_band(-1 - L24_hi, L25_hi)), bit32_bxor(L24_hi, bit32_band(-1 - L25_hi, L21_hi)), bit32_bxor(L25_hi, bit32_band(-1 - L21_hi, L22_hi)), bit32_bxor(L21_hi, bit32_band(-1 - L22_hi, L23_hi)), bit32_bxor(L22_hi, bit32_band(-1 - L23_hi, L24_hi))
				L01_lo = bit32_bxor(L01_lo, RC_lo[round_idx])
				L01_hi = L01_hi + RC_hi[round_idx] -- RC_hi[] is either 0 or 0x80000000, so we could use fast addition instead of slow XOR
			end

			lanes_lo[1] = L01_lo
			lanes_hi[1] = L01_hi
			lanes_lo[2] = L02_lo
			lanes_hi[2] = L02_hi
			lanes_lo[3] = L03_lo
			lanes_hi[3] = L03_hi
			lanes_lo[4] = L04_lo
			lanes_hi[4] = L04_hi
			lanes_lo[5] = L05_lo
			lanes_hi[5] = L05_hi
			lanes_lo[6] = L06_lo
			lanes_hi[6] = L06_hi
			lanes_lo[7] = L07_lo
			lanes_hi[7] = L07_hi
			lanes_lo[8] = L08_lo
			lanes_hi[8] = L08_hi
			lanes_lo[9] = L09_lo
			lanes_hi[9] = L09_hi
			lanes_lo[10] = L10_lo
			lanes_hi[10] = L10_hi
			lanes_lo[11] = L11_lo
			lanes_hi[11] = L11_hi
			lanes_lo[12] = L12_lo
			lanes_hi[12] = L12_hi
			lanes_lo[13] = L13_lo
			lanes_hi[13] = L13_hi
			lanes_lo[14] = L14_lo
			lanes_hi[14] = L14_hi
			lanes_lo[15] = L15_lo
			lanes_hi[15] = L15_hi
			lanes_lo[16] = L16_lo
			lanes_hi[16] = L16_hi
			lanes_lo[17] = L17_lo
			lanes_hi[17] = L17_hi
			lanes_lo[18] = L18_lo
			lanes_hi[18] = L18_hi
			lanes_lo[19] = L19_lo
			lanes_hi[19] = L19_hi
			lanes_lo[20] = L20_lo
			lanes_hi[20] = L20_hi
			lanes_lo[21] = L21_lo
			lanes_hi[21] = L21_hi
			lanes_lo[22] = L22_lo
			lanes_hi[22] = L22_hi
			lanes_lo[23] = L23_lo
			lanes_hi[23] = L23_hi
			lanes_lo[24] = L24_lo
			lanes_hi[24] = L24_hi
			lanes_lo[25] = L25_lo
			lanes_hi[25] = L25_hi
		end
	end

	--------------------------------------------------------------------------------
	-- MAGIC NUMBERS CALCULATOR
	--------------------------------------------------------------------------------
	-- Q:
	--    Is 53-bit "double" math enough to calculate square roots and cube roots of primes with 64 correct bits after decimal point?
	-- A:
	--    Yes, 53-bit "double" arithmetic is enough.
	--    We could obtain first 40 bits by direct calculation of p^(1/3) and next 40 bits by one step of Newton's method.
	do
		local function mul(src1, src2, factor, result_length)
			-- src1, src2 - long integers (arrays of digits in base TWO_POW_24)
			-- factor - small integer
			-- returns long integer result (src1 * src2 * factor) and its floating point approximation
			local result, carry, value, weight = table.create(result_length), 0, 0, 1
			for j = 1, result_length do
				for k = math.max(1, j + 1 - #src2), math.min(j, #src1) do
					carry = carry + factor * src1[k] * src2[j + 1 - k] -- "int32" is not enough for multiplication result, that's why "factor" must be of type "double"
				end

				local digit = carry % TWO_POW_24
				result[j] = math.floor(digit)
				carry = (carry - digit) / TWO_POW_24
				value = value + digit * weight
				weight = weight * TWO_POW_24
			end

			return result, value
		end

		local idx, step, p, one, sqrt_hi, sqrt_lo = 0, {4, 1, 2, -2, 2}, 4, {1}, sha2_H_hi, sha2_H_lo
		repeat
			p = p + step[p % 6]
			local d = 1
			repeat
				d = d + step[d % 6]
				if d * d > p then
					-- next prime number is found
					local root = p ^ (1 / 3)
					local R = root * TWO_POW_40
					R = mul(table.create(1, math.floor(R)), one, 1, 2)
					local _, delta = mul(R, mul(R, R, 1, 4), -1, 4)
					local hi = R[2] % 65536 * 65536 + math.floor(R[1] / 256)
					local lo = R[1] % 256 * 16777216 + math.floor(delta * (TWO_POW_NEG_56 / 3) * root / p)

					if idx < 16 then
						root = math.sqrt(p)
						R = root * TWO_POW_40
						R = mul(table.create(1, math.floor(R)), one, 1, 2)
						_, delta = mul(R, R, -1, 2)
						local hi = R[2] % 65536 * 65536 + math.floor(R[1] / 256)
						local lo = R[1] % 256 * 16777216 + math.floor(delta * TWO_POW_NEG_17 / root)
						local idx = idx % 8 + 1
						sha2_H_ext256[224][idx] = lo
						sqrt_hi[idx], sqrt_lo[idx] = hi, lo + hi * hi_factor
						if idx > 7 then
							sqrt_hi, sqrt_lo = sha2_H_ext512_hi[384], sha2_H_ext512_lo[384]
						end
					end

					idx = idx + 1
					sha2_K_hi[idx], sha2_K_lo[idx] = hi, lo % K_lo_modulo + hi * hi_factor
					break
				end
			until p % d == 0
		until idx > 79
	end

	-- Calculating IVs for SHA512/224 and SHA512/256
	for width = 224, 256, 32 do
		local H_lo, H_hi = {}, nil
		if XOR64A5 then
			for j = 1, 8 do
				H_lo[j] = XOR64A5(sha2_H_lo[j])
			end
		else
			H_hi = {}
			for j = 1, 8 do
				H_lo[j] = bit32_bxor(sha2_H_lo[j], 0xA5A5A5A5) % 4294967296
				H_hi[j] = bit32_bxor(sha2_H_hi[j], 0xA5A5A5A5) % 4294967296
			end
		end

		sha512_feed_128(H_lo, H_hi, "SHA-512/" .. tostring(width) .. "\128" .. string.rep("\0", 115) .. "\88", 0, 128)
		sha2_H_ext512_lo[width] = H_lo
		sha2_H_ext512_hi[width] = H_hi
	end

	-- Constants for MD5
	do
		for idx = 1, 64 do
			-- we can't use formula math.floor(abs(sin(idx))*TWO_POW_32) because its result may be beyond integer range on Lua built with 32-bit integers
			local hi, lo = math.modf(math.abs(math.sin(idx)) * TWO_POW_16)
			md5_K[idx] = hi * 65536 + math.floor(lo * TWO_POW_16)
		end
	end

	-- Constants for SHA3
	do
		local sh_reg = 29
		local function next_bit()
			local r = sh_reg % 2
			sh_reg = bit32_bxor((sh_reg - r) / 2, 142 * r)
			return r
		end

		for idx = 1, 24 do
			local lo, m = 0, nil
			for _ = 1, 6 do
				m = m and m * m * 2 or 1
				lo = lo + next_bit() * m
			end

			local hi = next_bit() * m
			sha3_RC_hi[idx], sha3_RC_lo[idx] = hi, lo + hi * hi_factor_keccak
		end
	end

	--------------------------------------------------------------------------------
	-- MAIN FUNCTIONS
	--------------------------------------------------------------------------------
	local function sha256ext(width, message)
		-- Create an instance (private objects for current calculation)
		local Array256 = sha2_H_ext256[width] -- # == 8
		local length, tail = 0, ""
		local H = table.create(8)
		H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8] = Array256[1], Array256[2], Array256[3], Array256[4], Array256[5], Array256[6], Array256[7], Array256[8]

		local function partial(message_part)
			if message_part then
				local partLength = #message_part
				if tail then
					length = length + partLength
					local offs = 0
					local tailLength = #tail
					if tail ~= "" and tailLength + partLength >= 64 then
						offs = 64 - tailLength
						sha256_feed_64(H, tail .. string.sub(message_part, 1, offs), 0, 64)
						tail = ""
					end

					local size = partLength - offs
					local size_tail = size % 64
					sha256_feed_64(H, message_part, offs, size - size_tail)
					tail = tail .. string.sub(message_part, partLength + 1 - size_tail)
					return partial
				else
					error("Adding more chunks is not allowed after receiving the result", 2)
				end
			else
				if tail then
					local final_blocks = table.create(10) --{tail, "\128", string.rep("\0", (-9 - length) % 64 + 1)}
					final_blocks[1] = tail
					final_blocks[2] = "\128"
					final_blocks[3] = string.rep("\0", (-9 - length) % 64 + 1)

					tail = nil
					-- Assuming user data length is shorter than (TWO_POW_53)-9 bytes
					-- Anyway, it looks very unrealistic that someone would spend more than a year of calculations to process TWO_POW_53 bytes of data by using this Lua script :-)
					-- TWO_POW_53 bytes = TWO_POW_56 bits, so "bit-counter" fits in 7 bytes
					length = length * (8 / TWO56_POW_7) -- convert "byte-counter" to "bit-counter" and move decimal point to the left
					for j = 4, 10 do
						length = length % 1 * 256
						final_blocks[j] = string.char(math.floor(length))
					end

					final_blocks = table.concat(final_blocks)
					sha256_feed_64(H, final_blocks, 0, #final_blocks)
					local max_reg = width / 32
					for j = 1, max_reg do
						H[j] = string.format("%08x", H[j] % 4294967296)
					end

					H = table.concat(H, "", 1, max_reg)
				end

				return H
			end
		end

		if message then
			-- Actually perform calculations and return the SHA256 digest of a message
			return partial(message)()
		else
			-- Return function for chunk-by-chunk loading
			-- User should feed every chunk of input data as single argument to this function and finally get SHA256 digest by invoking this function without an argument
			return partial
		end
	end

	local function sha512ext(width, message)

		-- Create an instance (private objects for current calculation)
		local length, tail, H_lo, H_hi = 0, "", table.pack(table.unpack(sha2_H_ext512_lo[width])), not HEX64 and table.pack(table.unpack(sha2_H_ext512_hi[width]))

		local function partial(message_part)
			if message_part then
				local partLength = #message_part
				if tail then
					length = length + partLength
					local offs = 0
					if tail ~= "" and #tail + partLength >= 128 then
						offs = 128 - #tail
						sha512_feed_128(H_lo, H_hi, tail .. string.sub(message_part, 1, offs), 0, 128)
						tail = ""
					end

					local size = partLength - offs
					local size_tail = size % 128
					sha512_feed_128(H_lo, H_hi, message_part, offs, size - size_tail)
					tail = tail .. string.sub(message_part, partLength + 1 - size_tail)
					return partial
				else
					error("Adding more chunks is not allowed after receiving the result", 2)
				end
			else
				if tail then
					local final_blocks = table.create(3) --{tail, "\128", string.rep("\0", (-17-length) % 128 + 9)}
					final_blocks[1] = tail
					final_blocks[2] = "\128"
					final_blocks[3] = string.rep("\0", (-17 - length) % 128 + 9)

					tail = nil
					-- Assuming user data length is shorter than (TWO_POW_53)-17 bytes
					-- TWO_POW_53 bytes = TWO_POW_56 bits, so "bit-counter" fits in 7 bytes
					length = length * (8 / TWO56_POW_7) -- convert "byte-counter" to "bit-counter" and move floating point to the left
					for j = 4, 10 do
						length = length % 1 * 256
						final_blocks[j] = string.char(math.floor(length))
					end

					final_blocks = table.concat(final_blocks)
					sha512_feed_128(H_lo, H_hi, final_blocks, 0, #final_blocks)
					local max_reg = math.ceil(width / 64)

					if HEX64 then
						for j = 1, max_reg do
							H_lo[j] = HEX64(H_lo[j])
						end
					else
						for j = 1, max_reg do
							H_lo[j] = string.format("%08x", H_hi[j] % 4294967296) .. string.format("%08x", H_lo[j] % 4294967296)
						end

						H_hi = nil
					end

					H_lo = string.sub(table.concat(H_lo, "", 1, max_reg), 1, width / 4)
				end

				return H_lo
			end
		end

		if message then
			-- Actually perform calculations and return the SHA512 digest of a message
			return partial(message)()
		else
			-- Return function for chunk-by-chunk loading
			-- User should feed every chunk of input data as single argument to this function and finally get SHA512 digest by invoking this function without an argument
			return partial
		end
	end

	local function md5(message)

		-- Create an instance (private objects for current calculation)
		local H, length, tail = table.create(4), 0, ""
		H[1], H[2], H[3], H[4] = md5_sha1_H[1], md5_sha1_H[2], md5_sha1_H[3], md5_sha1_H[4]

		local function partial(message_part)
			if message_part then
				local partLength = #message_part
				if tail then
					length = length + partLength
					local offs = 0
					if tail ~= "" and #tail + partLength >= 64 then
						offs = 64 - #tail
						md5_feed_64(H, tail .. string.sub(message_part, 1, offs), 0, 64)
						tail = ""
					end

					local size = partLength - offs
					local size_tail = size % 64
					md5_feed_64(H, message_part, offs, size - size_tail)
					tail = tail .. string.sub(message_part, partLength + 1 - size_tail)
					return partial
				else
					error("Adding more chunks is not allowed after receiving the result", 2)
				end
			else
				if tail then
					local final_blocks = table.create(3) --{tail, "\128", string.rep("\0", (-9 - length) % 64)}
					final_blocks[1] = tail
					final_blocks[2] = "\128"
					final_blocks[3] = string.rep("\0", (-9 - length) % 64)
					tail = nil
					length = length * 8 -- convert "byte-counter" to "bit-counter"
					for j = 4, 11 do
						local low_byte = length % 256
						final_blocks[j] = string.char(low_byte)
						length = (length - low_byte) / 256
					end

					final_blocks = table.concat(final_blocks)
					md5_feed_64(H, final_blocks, 0, #final_blocks)
					for j = 1, 4 do
						H[j] = string.format("%08x", H[j] % 4294967296)
					end

					H = string.gsub(table.concat(H), "(..)(..)(..)(..)", "%4%3%2%1")
				end

				return H
			end
		end

		if message then
			-- Actually perform calculations and return the MD5 digest of a message
			return partial(message)()
		else
			-- Return function for chunk-by-chunk loading
			-- User should feed every chunk of input data as single argument to this function and finally get MD5 digest by invoking this function without an argument
			return partial
		end
	end

	local function sha1(message)
		-- Create an instance (private objects for current calculation)
		local H, length, tail = table.pack(table.unpack(md5_sha1_H)), 0, ""

		local function partial(message_part)
			if message_part then
				local partLength = #message_part
				if tail then
					length = length + partLength
					local offs = 0
					if tail ~= "" and #tail + partLength >= 64 then
						offs = 64 - #tail
						sha1_feed_64(H, tail .. string.sub(message_part, 1, offs), 0, 64)
						tail = ""
					end

					local size = partLength - offs
					local size_tail = size % 64
					sha1_feed_64(H, message_part, offs, size - size_tail)
					tail = tail .. string.sub(message_part, partLength + 1 - size_tail)
					return partial
				else
					error("Adding more chunks is not allowed after receiving the result", 2)
				end
			else
				if tail then
					local final_blocks = table.create(10) --{tail, "\128", string.rep("\0", (-9 - length) % 64 + 1)}
					final_blocks[1] = tail
					final_blocks[2] = "\128"
					final_blocks[3] = string.rep("\0", (-9 - length) % 64 + 1)
					tail = nil

					-- Assuming user data length is shorter than (TWO_POW_53)-9 bytes
					-- TWO_POW_53 bytes = TWO_POW_56 bits, so "bit-counter" fits in 7 bytes
					length = length * (8 / TWO56_POW_7) -- convert "byte-counter" to "bit-counter" and move decimal point to the left
					for j = 4, 10 do
						length = length % 1 * 256
						final_blocks[j] = string.char(math.floor(length))
					end

					final_blocks = table.concat(final_blocks)
					sha1_feed_64(H, final_blocks, 0, #final_blocks)
					for j = 1, 5 do
						H[j] = string.format("%08x", H[j] % 4294967296)
					end

					H = table.concat(H)
				end

				return H
			end
		end

		if message then
			-- Actually perform calculations and return the SHA-1 digest of a message
			return partial(message)()
		else
			-- Return function for chunk-by-chunk loading
			-- User should feed every chunk of input data as single argument to this function and finally get SHA-1 digest by invoking this function without an argument
			return partial
		end
	end

	local function keccak(block_size_in_bytes, digest_size_in_bytes, is_SHAKE, message)
		-- "block_size_in_bytes" is multiple of 8
		if type(digest_size_in_bytes) ~= "number" then
			-- arguments in SHAKE are swapped:
			--    NIST FIPS 202 defines SHAKE(message,num_bits)
			--    this module   defines SHAKE(num_bytes,message)
			-- it's easy to forget about this swap, hence the check
			error("Argument 'digest_size_in_bytes' must be a number", 2)
		end

		-- Create an instance (private objects for current calculation)
		local tail, lanes_lo, lanes_hi = "", table.create(25, 0), hi_factor_keccak == 0 and table.create(25, 0)
		local result

		--~     pad the input N using the pad function, yielding a padded bit string P with a length divisible by r (such that n = len(P)/r is integer),
		--~     break P into n consecutive r-bit pieces P0, ..., Pn-1 (last is zero-padded)
		--~     initialize the state S to a string of b 0 bits.
		--~     absorb the input into the state: For each block Pi,
		--~         extend Pi at the end by a string of c 0 bits, yielding one of length b,
		--~         XOR that with S and
		--~         apply the block permutation f to the result, yielding a new state S
		--~     initialize Z to be the empty string
		--~     while the length of Z is less than d:
		--~         append the first r bits of S to Z
		--~         if Z is still less than d bits long, apply f to S, yielding a new state S.
		--~     truncate Z to d bits
		local function partial(message_part)
			if message_part then
				local partLength = #message_part
				if tail then
					local offs = 0
					if tail ~= "" and #tail + partLength >= block_size_in_bytes then
						offs = block_size_in_bytes - #tail
						keccak_feed(lanes_lo, lanes_hi, tail .. string.sub(message_part, 1, offs), 0, block_size_in_bytes, block_size_in_bytes)
						tail = ""
					end

					local size = partLength - offs
					local size_tail = size % block_size_in_bytes
					keccak_feed(lanes_lo, lanes_hi, message_part, offs, size - size_tail, block_size_in_bytes)
					tail = tail .. string.sub(message_part, partLength + 1 - size_tail)
					return partial
				else
					error("Adding more chunks is not allowed after receiving the result", 2)
				end
			else
				if tail then
					-- append the following bits to the message: for usual SHA3: 011(0*)1, for SHAKE: 11111(0*)1
					local gap_start = is_SHAKE and 31 or 6
					tail = tail .. (#tail + 1 == block_size_in_bytes and string.char(gap_start + 128) or string.char(gap_start) .. string.rep("\0", (-2 - #tail) % block_size_in_bytes) .. "\128")
					keccak_feed(lanes_lo, lanes_hi, tail, 0, #tail, block_size_in_bytes)
					tail = nil

					local lanes_used = 0
					local total_lanes = math.floor(block_size_in_bytes / 8)
					local qwords = {}

					local function get_next_qwords_of_digest(qwords_qty)
						-- returns not more than 'qwords_qty' qwords ('qwords_qty' might be non-integer)
						-- doesn't go across keccak-buffer boundary
						-- block_size_in_bytes is a multiple of 8, so, keccak-buffer contains integer number of qwords
						if lanes_used >= total_lanes then
							keccak_feed(lanes_lo, lanes_hi, "\0\0\0\0\0\0\0\0", 0, 8, 8)
							lanes_used = 0
						end

						qwords_qty = math.floor(math.min(qwords_qty, total_lanes - lanes_used))
						if hi_factor_keccak ~= 0 then
							for j = 1, qwords_qty do
								qwords[j] = HEX64(lanes_lo[lanes_used + j - 1 + lanes_index_base])
							end
						else
							for j = 1, qwords_qty do
								qwords[j] = string.format("%08x", lanes_hi[lanes_used + j] % 4294967296) .. string.format("%08x", lanes_lo[lanes_used + j] % 4294967296)
							end
						end

						lanes_used = lanes_used + qwords_qty
						return string.gsub(table.concat(qwords, "", 1, qwords_qty), "(..)(..)(..)(..)(..)(..)(..)(..)", "%8%7%6%5%4%3%2%1"), qwords_qty * 8
					end

					local parts = {} -- digest parts
					local last_part, last_part_size = "", 0

					local function get_next_part_of_digest(bytes_needed)
						-- returns 'bytes_needed' bytes, for arbitrary integer 'bytes_needed'
						bytes_needed = bytes_needed or 1
						if bytes_needed <= last_part_size then
							last_part_size = last_part_size - bytes_needed
							local part_size_in_nibbles = bytes_needed * 2
							local result = string.sub(last_part, 1, part_size_in_nibbles)
							last_part = string.sub(last_part, part_size_in_nibbles + 1)
							return result
						end

						local parts_qty = 0
						if last_part_size > 0 then
							parts_qty = 1
							parts[parts_qty] = last_part
							bytes_needed = bytes_needed - last_part_size
						end

						-- repeats until the length is enough
						while bytes_needed >= 8 do
							local next_part, next_part_size = get_next_qwords_of_digest(bytes_needed / 8)
							parts_qty = parts_qty + 1
							parts[parts_qty] = next_part
							bytes_needed = bytes_needed - next_part_size
						end

						if bytes_needed > 0 then
							last_part, last_part_size = get_next_qwords_of_digest(1)
							parts_qty = parts_qty + 1
							parts[parts_qty] = get_next_part_of_digest(bytes_needed)
						else
							last_part, last_part_size = "", 0
						end

						return table.concat(parts, "", 1, parts_qty)
					end

					if digest_size_in_bytes < 0 then
						result = get_next_part_of_digest
					else
						result = get_next_part_of_digest(digest_size_in_bytes)
					end

				end

				return result
			end
		end

		if message then
			-- Actually perform calculations and return the SHA3 digest of a message
			return partial(message)()
		else
			-- Return function for chunk-by-chunk loading
			-- User should feed every chunk of input data as single argument to this function and finally get SHA3 digest by invoking this function without an argument
			return partial
		end
	end

	local function HexToBinFunction(hh)
		return string.char(tonumber(hh, 16))
	end

	local function hex2bin(hex_string)
		return (string.gsub(hex_string, "%x%x", HexToBinFunction))
	end

	local base64_symbols = {
		["+"] = 62, ["-"] = 62, [62] = "+";
		["/"] = 63, ["_"] = 63, [63] = "/";
		["="] = -1, ["."] = -1, [-1] = "=";
	}

	local symbol_index = 0
	for j, pair in {"AZ", "az", "09"} do
		for ascii = string.byte(pair), string.byte(pair, 2) do
			local ch = string.char(ascii)
			base64_symbols[ch] = symbol_index
			base64_symbols[symbol_index] = ch
			symbol_index = symbol_index + 1
		end
	end

	local function bin2base64(binary_string)
		local stringLength = #binary_string
		local result = table.create(math.ceil(stringLength / 3))
		local length = 0

		for pos = 1, #binary_string, 3 do
			local c1, c2, c3, c4 = string.byte(string.sub(binary_string, pos, pos + 2) .. '\0', 1, -1)
			length = length + 1
			result[length] =
				base64_symbols[math.floor(c1 / 4)] ..
				base64_symbols[c1 % 4 * 16 + math.floor(c2 / 16)] ..
				base64_symbols[c3 and c2 % 16 * 4 + math.floor(c3 / 64) or -1] ..
				base64_symbols[c4 and c3 % 64 or -1]
		end

		return table.concat(result)
	end

	local function base642bin(base64_string)
		local result, chars_qty = {}, 3
		for pos, ch in string.gmatch(string.gsub(base64_string, "%s+", ""), "()(.)") do
			local code = base64_symbols[ch]
			if code < 0 then
				chars_qty = chars_qty - 1
				code = 0
			end

			local idx = pos % 4
			if idx > 0 then
				result[-idx] = code
			else
				local c1 = result[-1] * 4 + math.floor(result[-2] / 16)
				local c2 = (result[-2] % 16) * 16 + math.floor(result[-3] / 4)
				local c3 = (result[-3] % 4) * 64 + code
				result[#result + 1] = string.sub(string.char(c1, c2, c3), 1, chars_qty)
			end
		end

		return table.concat(result)
	end

	local block_size_for_HMAC -- this table will be initialized at the end of the module
	--local function pad_and_xor(str, result_length, byte_for_xor)
	--	return string.gsub(str, ".", function(c)
	--		return string.char(bit32_bxor(string.byte(c), byte_for_xor))
	--	end) .. string.rep(string.char(byte_for_xor), result_length - #str)
	--end

	-- For the sake of speed of converting hexes to strings, there's a map of the conversions here
	local BinaryStringMap = {}
	for Index = 0, 255 do
		BinaryStringMap[string.format("%02x", Index)] = string.char(Index)
	end

	-- Update 02.14.20 - added AsBinary for easy GameAnalytics replacement.
	local function hmac(hash_func, key, message, AsBinary)
		-- Create an instance (private objects for current calculation)
		local block_size = block_size_for_HMAC[hash_func]
		if not block_size then
			error("Unknown hash function", 2)
		end

		local KeyLength = #key
		if KeyLength > block_size then
			key = string.gsub(hash_func(key), "%x%x", HexToBinFunction)
			KeyLength = #key
		end

		local append = hash_func()(string.gsub(key, ".", function(c)
			return string.char(bit32_bxor(string.byte(c), 0x36))
		end) .. string.rep("6", block_size - KeyLength)) -- 6 = string.char(0x36)

		local result

		local function partial(message_part)
			if not message_part then
				result = result or hash_func(
					string.gsub(key, ".", function(c)
						return string.char(bit32_bxor(string.byte(c), 0x5c))
					end) .. string.rep("\\", block_size - KeyLength) -- \ = string.char(0x5c)
						.. (string.gsub(append(), "%x%x", HexToBinFunction))
				)

				return result
			elseif result then
				error("Adding more chunks is not allowed after receiving the result", 2)
			else
				append(message_part)
				return partial
			end
		end

		if message then
			-- Actually perform calculations and return the HMAC of a message
			local FinalMessage = partial(message)()
			return AsBinary and (string.gsub(FinalMessage, "%x%x", BinaryStringMap)) or FinalMessage
		else
			-- Return function for chunk-by-chunk loading of a message
			-- User should feed every chunk of the message as single argument to this function and finally get HMAC by invoking this function without an argument
			return partial
		end
	end

	local sha = {
		md5 = md5,
		sha1 = sha1,
		-- SHA2 hash functions:
		sha224 = function(message)
			return sha256ext(224, message)
		end;

		sha256 = function(message)
			return sha256ext(256, message)
		end;

		sha512_224 = function(message)
			return sha512ext(224, message)
		end;

		sha512_256 = function(message)
			return sha512ext(256, message)
		end;

		sha384 = function(message)
			return sha512ext(384, message)
		end;

		sha512 = function(message)
			return sha512ext(512, message)
		end;

		-- SHA3 hash functions:
		sha3_224 = function(message)
			return keccak((1600 - 2 * 224) / 8, 224 / 8, false, message)
		end;

		sha3_256 = function(message)
			return keccak((1600 - 2 * 256) / 8, 256 / 8, false, message)
		end;

		sha3_384 = function(message)
			return keccak((1600 - 2 * 384) / 8, 384 / 8, false, message)
		end;

		sha3_512 = function(message)
			return keccak((1600 - 2 * 512) / 8, 512 / 8, false, message)
		end;

		shake128 = function(message, digest_size_in_bytes)
			return keccak((1600 - 2 * 128) / 8, digest_size_in_bytes, true, message)
		end;

		shake256 = function(message, digest_size_in_bytes)
			return keccak((1600 - 2 * 256) / 8, digest_size_in_bytes, true, message)
		end;

		-- misc utilities:
		hmac = hmac; -- HMAC(hash_func, key, message) is applicable to any hash function from this module except SHAKE*
		hex_to_bin = hex2bin; -- converts hexadecimal representation to binary string
		base64_to_bin = base642bin; -- converts base64 representation to binary string
		bin_to_base64 = bin2base64; -- converts binary string to base64 representation
		-- base64_encode = Base64.Encode;
		-- base64_decode = Base64.Decode;
	}

	block_size_for_HMAC = {
		[sha.md5] = 64;
		[sha.sha1] = 64;
		[sha.sha224] = 64;
		[sha.sha256] = 64;
		[sha.sha512_224] = 128;
		[sha.sha512_256] = 128;
		[sha.sha384] = 128;
		[sha.sha512] = 128;
		[sha.sha3_224] = (1600 - 2 * 224) / 8;
		[sha.sha3_256] = (1600 - 2 * 256) / 8;
		[sha.sha3_384] = (1600 - 2 * 384) / 8;
		[sha.sha3_512] = (1600 - 2 * 512) / 8;
	}

	return sha
end)()
local lz4 = (function()
	--!strict
	-- metatablecat 2022

	local lz4 = {}

	type Streamer = {
		Offset: number,
		Source: string,
		Length: number,
		IsFinished: boolean,
		LastUnreadBytes: number,

		read: (Streamer, len: number?, shiftOffset: boolean?) -> string,
		seek: (Streamer, len: number) -> (),
		append: (Streamer, newData: string) -> (),
		toEnd: (Streamer) -> ()
	}

	type BlockData = {
		[number]: {
			Literal: string,
			LiteralLength: number,
			MatchOffset: number?,
			MatchLength: number?
		}
	}

	local function plainFind(str, pat)
		return string.find(str, pat, 0, true)
	end

	local function streamer(str): Streamer
		local Stream = {}
		Stream.Offset = 0
		Stream.Source = str
		Stream.Length = string.len(str)
		Stream.IsFinished = false	
		Stream.LastUnreadBytes = 0

		function Stream.read(self: Streamer, len: number?, shift: boolean?): string
			local len = len or 1
			local shift = if shift ~= nil then shift else true
			local dat = string.sub(self.Source, self.Offset + 1, self.Offset + len)

			local dataLength = string.len(dat)
			local unreadBytes = len - dataLength

			if shift then
				self:seek(len)
			end

			self.LastUnreadBytes = unreadBytes
			return dat
		end

		function Stream.seek(self: Streamer, len: number)
			local len = len or 1

			self.Offset = math.clamp(self.Offset + len, 0, self.Length)
			self.IsFinished = self.Offset >= self.Length
		end

		function Stream.append(self: Streamer, newData: string)
			-- adds new data to the end of a stream
			self.Source ..= newData
			self.Length = string.len(self.Source)
			self:seek(0) --hacky but forces a recalculation of the isFinished flag
		end

		function Stream.toEnd(self: Streamer)
			self:seek(self.Length)
		end

		return Stream
	end

	function lz4.compress(str: string): string
		local blocks: BlockData = {}
		local iostream = streamer(str)

		if iostream.Length > 12 then
			local firstFour = iostream:read(4)

			local processed = firstFour
			local lit = firstFour
			local match = ""
			local LiteralPushValue = ""
			local pushToLiteral = true

			repeat
				pushToLiteral = true
				local nextByte = iostream:read()

				if plainFind(processed, nextByte) then
					local next3 = iostream:read(3, false)

					if string.len(next3) < 3 then
						--push bytes to literal block then break
						LiteralPushValue = nextByte .. next3
						iostream:seek(3)
					else
						match = nextByte .. next3

						local matchPos = plainFind(processed, match)
						if matchPos then
							iostream:seek(3)
							repeat
								local nextMatchByte = iostream:read(1, false)
								local newResult = match .. nextMatchByte

								local repos = plainFind(processed, newResult) 
								if repos then
									match = newResult
									matchPos = repos
									iostream:seek(1)
								end
							until not plainFind(processed, newResult) or iostream.IsFinished

							local matchLen = string.len(match)
							local pushMatch = true

							if iostream.Length - iostream.Offset <= 5 then
								LiteralPushValue = match
								pushMatch = false
								--better safe here, dont bother pushing to match ever
							end

							if pushMatch then
								pushToLiteral = false

								-- gets the position from the end of processed, then slaps it onto processed
								local realPosition = string.len(processed) - matchPos
								processed = processed .. match

								table.insert(blocks, {
									Literal = lit,
									LiteralLength = string.len(lit),
									MatchOffset = realPosition + 1,
									MatchLength = matchLen,
								})
								lit = ""
							end
						else
							LiteralPushValue = nextByte
						end
					end
				else
					LiteralPushValue = nextByte
				end

				if pushToLiteral then
					lit = lit .. LiteralPushValue
					processed = processed .. nextByte
				end
			until iostream.IsFinished
			table.insert(blocks, {
				Literal = lit,
				LiteralLength = string.len(lit)
			})
		else
			local str = iostream.Source
			blocks[1] = {
				Literal = str,
				LiteralLength = string.len(str)
			}
		end

		-- generate the output chunk
		-- %s is for adding header
		local output = string.rep("\x00", 4)
		local function write(char)
			output = output .. char
		end
		-- begin working through chunks
		for chunkNum, chunk in blocks do
			local litLen = chunk.LiteralLength
			local matLen = (chunk.MatchLength or 4) - 4

			-- create token
			local tokenLit = math.clamp(litLen, 0, 15)
			local tokenMat = math.clamp(matLen, 0, 15)

			local token = bit32.lshift(tokenLit, 4) + tokenMat
			write(string.pack("<I1", token))

			if litLen >= 15 then
				litLen = litLen - 15
				--begin packing extra bytes
				repeat
					local nextToken = math.clamp(litLen, 0, 0xFF)
					write(string.pack("<I1", nextToken))
					if nextToken == 0xFF then
						litLen = litLen - 255
					end
				until nextToken < 0xFF
			end

			-- push raw lit data
			write(chunk.Literal)

			if chunkNum ~= #blocks then
				-- push offset as u16
				write(string.pack("<I2", chunk.MatchOffset))

				-- pack extra match bytes
				if matLen >= 15 then
					matLen = matLen - 15

					repeat
						local nextToken = math.clamp(matLen, 0, 0xFF)
						write(string.pack("<I1", nextToken))
						if nextToken == 0xFF then
							matLen = matLen - 255
						end
					until nextToken < 0xFF
				end
			end
		end
		--append chunks
		local compLen = string.len(output) - 4
		local decompLen = iostream.Length

		return string.pack("<I4", compLen) .. string.pack("<I4", decompLen) .. output
	end

	function lz4.decompress(lz4data: string): string
		local inputStream = streamer(lz4data)

		local compressedLen = string.unpack("<I4", inputStream:read(4))
		local decompressedLen = string.unpack("<I4", inputStream:read(4))
		local reserved = string.unpack("<I4", inputStream:read(4))

		if compressedLen == 0 then
			return inputStream:read(decompressedLen)
		end

		local outputStream = streamer("")

		repeat
			local token = string.byte(inputStream:read())
			local litLen = bit32.rshift(token, 4)
			local matLen = bit32.band(token, 15) + 4

			if litLen >= 15 then
				repeat
					local nextByte = string.byte(inputStream:read())
					litLen += nextByte
				until nextByte ~= 0xFF
			end

			local literal = inputStream:read(litLen)
			outputStream:append(literal)
			outputStream:toEnd()
			if outputStream.Length < decompressedLen then
				--match
				local offset = string.unpack("<I2", inputStream:read(2))
				if matLen >= 19 then
					repeat
						local nextByte = string.byte(inputStream:read())
						matLen += nextByte
					until nextByte ~= 0xFF
				end

				outputStream:seek(-offset)
				local pos = outputStream.Offset
				local match = outputStream:read(matLen)
				local unreadBytes = outputStream.LastUnreadBytes
				local extra
				if unreadBytes then
					repeat
						outputStream.Offset = pos
						extra = outputStream:read(unreadBytes)
						unreadBytes = outputStream.LastUnreadBytes
						match ..= extra
					until unreadBytes <= 0
				end

				outputStream:append(match)
				outputStream:toEnd()
			end

		until outputStream.Length >= decompressedLen

		return outputStream.Source
	end

	return lz4
end)()

local setthread = {}

changedidentity = false

local thread = {}

thread.thread_identity = 1356

-- objects
local hidden_ui_container = Instance.new("Folder")
hidden_ui_container.Name = "\fsavage-hui"
hidden_ui_container.RobloxLocked = true
hidden_ui_container.Parent = game:FindService("CoreGui"):FindFirstChild("RobloxGui")

-- variables
local instances_reg = setmetatable({ [game] = true }, { __mode = "ks" })
local touchers_reg = setmetatable({}, { __mode = "ks" })

-- functions
local _loaded_saveinstance

local function addToInstancesReg(descendant: Instance)
	if instances_reg[descendant] then
		return
	end
	instances_reg[descendant] = true
end

local function filterAllInstances(filter)
	local result = {}
	local idx = 1

	for instance in instances_reg do
		if not (filter(instance)) then
			continue
		end
		result[idx] = instance
		idx += 1
	end
	return result
end

-- init
game.DescendantAdded:Connect(addToInstancesReg)
game.DescendantRemoving:Connect(addToInstancesReg)

for _, instance in game:GetDescendants() do
	addToInstancesReg(instance)
end

-- main
local instance_lib = {}

-- * general instance functions

function instance_lib.getinstances()
	return filterAllInstances(function()
		return true
	end)
end

function instance_lib.getnilinstances()
	return filterAllInstances(function(instance)
		return instance.Parent == nil
	end)
end

function instance_lib.getscripts()
	return filterAllInstances(function(instance)
		return instance:IsA("LocalScript") or instance:IsA("ModuleScript")
	end)
end

function instance_lib.getmodules()
	return filterAllInstances(function(instance)
		return instance:IsA("ModuleScript")
	end)
end

-- * other instance functions

function instance_lib.gethui()
	return hidden_ui_container
end

function instance_lib.spoofinstance(spoofing: Instance, new_instance: Instance)
	assert(typeof(spoofing) == "Instance", "arg #1 must be type Instance")
	assert(typeof(new_instance) == "Instance" or type(new_instance) == "number", "arg #2 must be type Instance") -- ? or number ?
	assert(spoofing.ClassName == new_instance.ClassName, "arg #2 Instance has different ClassName to arg #1 Instance")

	task.spawn(bridge.send, bridge, "spoof_instance", spoofing, new_instance)
end

function instance_lib.getinstanceaddress(instance)
	assert(typeof(instance) == "Instance", `arg #1 must be type Instance`)

	return bridge:send("get_instance_address", instance)
end

function instance_lib.firetouchinterest(toucher: BasePart, to_touch: BasePart, touch_value: number)
	assert(typeof(toucher) == "Instance" and toucher:IsA("BasePart"), `arg #1 must be BasePart`)
	assert(typeof(to_touch) == "Instance" and to_touch:IsA("BasePart"), `arg #2 must be BasePart`)
	assert(type(touch_value) == "number", "arg #3 must be type number")

	if not touchers_reg[toucher] then
		touchers_reg[toucher] = {}
	end

	local part_address = instance_lib.getinstanceaddress(to_touch)

	if touch_value == 0 then
		if touchers_reg[toucher][part_address] then
			return
		end
		local fake_part = Instance.new(to_touch.ClassName, to_touch)
		fake_part.CanCollide = false
		fake_part.CanQuery = false
		fake_part.CanTouch = true
		fake_part.Anchored = true
		fake_part.Transparency = 1

		instance_lib.spoofinstance(fake_part, to_touch)
		touchers_reg[toucher][part_address] = true

		task.spawn(function()
			while touchers_reg[toucher][part_address] do
				fake_part.CFrame = toucher.CFrame
				task.wait()
			end

			fake_part:Destroy()
		end)
	elseif touch_value == 1 then
		if not touchers_reg[toucher][part_address] then
			return
		end

		instance_lib.spoofinstance(to_touch, part_address)
		table.remove(touchers_reg[toucher], part_address)
	end
end

function instance_lib.fireclickdetector(clickdetector, distance)
	-- TODO: do distance
	assert(typeof(clickdetector) == "Instance" and clickdetector:IsA("ClickDetector"), `arg #1 must be ClickDetector`)
	if distance ~= nil then
		assert(type(distance) == "number", `arg #2 must be type number`)
	end
	local oldCDMaxActivationDistance = clickdetector.MaxActivationDistance
	local oldCDParent = clickdetector.Parent
	local tmpPart = Instance.new("Part")
	tmpPart.Parent = workspace
	tmpPart.CanCollide = false
	tmpPart.Anchored = true
	tmpPart.Transparency = 1
	tmpPart.Size = Vector3.new(30, 30, 30)
	clickdetector.Parent = tmpPart
	--instance_lib.spoofinstance(tmpPart, clickdetector.Parent) could use it
	clickdetector.MaxActivationDistance = 9e9

	local connection
	-- credits to quiving for that one
	connection = run_service.Heartbeat:Connect(function()
		local current_camera = workspace.CurrentCamera
		tmpPart.CFrame = current_camera.CFrame
			* CFrame.new(0, 0, -20)
			* CFrame.new(current_camera.CFrame.LookVector)

		game:GetService("VirtualUser"):ClickButton1(Vector2.new(20, 20), workspace:FindFirstChildOfClass("Camera").CFrame)
	end)

	clickdetector.MouseClick:Once(function()
		connection:Disconnect()
		clickdetector.MaxActivationDistance = oldCDMaxActivationDistance
		clickdetector.Parent = oldCDParent
		tmpPart:Destroy()
	end)
end

function instance_lib.fireproximityprompt(proximityprompt, amount, skip)
	assert(
		typeof(proximityprompt) == "Instance" and proximityprompt:IsA("ProximityPrompt"),
		`arg #1 must be ProximityPrompt`
	)

	if amount ~= nil then
		assert(type(amount) == "number", `arg #2 must be type number`)
		if skip ~= nil then
			assert(type(skip) == "boolean", `arg #3 must be type boolean`)
		end
	end

	local oldHoldDuration = proximityprompt.HoldDuration
	local oldMaxDistance = proximityprompt.MaxActivationDistance

	proximityprompt.MaxActivationDistance = 9e9 -- client replicated only
	proximityprompt:InputHoldBegin()

	for i = 1, amount or 1 do -- or 1 cuz number can be nil
		if skip then
			proximityprompt.HoldDuration = 0
		else
			task.wait(proximityprompt.HoldDuration + 0.01) -- better than wait()
		end
	end

	proximityprompt:InputHoldEnd()
	proximityprompt.MaxActivationDistance = oldMaxDistance
	proximityprompt.HoldDuration = oldHoldDuration
end

function instance_lib.isnetworkowner(part)
	assert(typeof(part) == "Instance" and part:IsA("BasePart"), `arg #1 must be BasePart`)
	if part.Anchored then
		return false
	end
	return part.ReceiveAge == 0
end

function instance_lib.setsimulationradius(newRadius, newMaxRadius)
	assert(newRadius, `arg #1 is missing`)
	assert(type(newRadius) == "number", `arg #1 must be type number`)

	local LocalPlayer = game:GetService("Players").LocalPlayer
	if LocalPlayer then
		LocalPlayer.SimulationRadius = newRadius
		LocalPlayer.MaximumSimulationRadius = newMaxRadius or newRadius
	end
end

function instance_lib.saveinstance(...)
	if not _loaded_saveinstance then
		local params = {
			RepoURL = "https://raw.githubusercontent.com/luau/SynSaveInstance/main/",
			SSI = "saveinstance",
		}

		local content = instance_lib.httpget(params.RepoURL .. params.SSI .. ".luau", true)
		_loaded_saveinstance = instance_lib.loadstring(content, params.SSI)()
	end

	return _loaded_saveinstance(...)
end

function instance_lib.isscriptable(instance, property_name)
	local success, Result = xpcall(instance.GetPropertyChangedSignal, function(result)
		return result
	end, instance, property_name)

	return (success or not string.find(Result, "scriptable", nil, true))
end

function instance_lib.getproperties(instance)
	assert(typeof(instance) == "Instance", `arg #1 must be type Instance`)

	return bridge:send("get_properties", instance) -- * All, including hidden (Should be {[property_name]=value} Format)
end

function instance_lib.gethiddenproperties(instance)
	assert(typeof(instance) == "Instance", `arg #1 must be type Instance`)

	local hidden_properties = {}

	-- TODO Edit below once getproperties returns prop-value pairs instead of array of names
	for _, property_name in instance_lib.getproperties(instance) do
		if not instance_lib.isscriptable(instance, property_name) then
			hidden_properties[property_name] = "STUB_VALUE"
		end
	end

	return hidden_properties
end

function instance_lib.gethiddenproperty(instance, property_name)
	assert(typeof(instance) == "Instance", `arg #1 must be type Instance`)
	assert(type(property_name) == "string", `arg #2 must be type string`)
	if instance_lib.isscriptable(instance, property_name) then
		return instance[property_name] -- * This will error if it's an invalid property but that should intended
	end

	return instance_lib.gethiddenproperties(instance)[property_name]

	-- local was_scriptable = instance_lib.setscriptable(instance, property_name, true)
	-- local o, value = pcall(function()
	--     return instance[property_name]
	-- end)
	-- if not was_scriptable then
	--     instance_lib.setscriptable(instance, property_name, was_scriptable)
	-- end
	-- if o then
	--     return value, was_scriptable
	-- else
	--     error(value, 2)
	-- end
end



function setthreadidentity(identity)
	changedidentity = true
	thread.thread_identity = identity
end

function getthreadidentity()
	if changedidentity == true then
		return thread.thread_identity
	end

	local function try(fn, ...)
		local o = pcall(fn, ...)
		return o
	end

	local ourresults = {
		-- ! ITS IMPORTANT WE DONT USE ANY METHODS HERE THAT WE SPOOF
		-- ! HOPEFULLY Security Tags of these dont change
		-- PluginSecurity (1)
		try(function()
			return game:GetJobsInfo()
		end),
		-- LocalUserSecurity (3)
		try(function()
			return workspace:ExperimentalSolverIsEnabled()
		end),
		--WritePlayerSecurity (4)
		try(Instance.new, "Player"),
		--RobloxScriptSecurity (5)
		try(function()
			return game:GetPlaySessionId()
		end),
		--RobloxSecurity (6)
		try(function()
			return Instance.new("SurfaceAppearance").TexturePack
		end),
		--NotAccessibleSecurity (7)
		try(function()
			Instance.new("MeshPart").HasJointOffset = false
		end),
	}
	local permissionChart =
		{ -- We go in reverse because LocalGui is equal to CommandBar in permissionChart it seems like (this way we can match properly, though we can't tell lvl 7 from 8 then but not like that's a big issue)
			{ true, true, false, false, false, false }, -- LocalGui [1]
			{ false, false, false, false, false, false }, -- GameScript [2]
			{ true, true, false, true, false, false }, -- ElevatedGameScript [3]
			{ true, true, false, false, false, false }, -- CommandBar [4]
			{ true, false, false, false, false, false }, -- StudioPlugin [5]
			{ true, true, false, true, false, false }, -- ElevatedStudioPlugin [6]
			{ true, true, true, true, true, true }, -- COM [7] Level 7 WOOHOO
			{ true, true, true, true, true, true }, -- WebService [8] WOW LVL 8
			{ false, false, true, true, false, false }, -- Replicator [9]
		}

	for level = #permissionChart, 1, -1 do
		local securityInfo = permissionChart[level]

		local match = true
		for i, canAccess in securityInfo do
			if canAccess ~= ourresults[i] then
				match = false
				break
			end
		end
		if match then
			return level
		end
	end
	return 0
end

local script_env

local scripts = {}

function scripts.getscriptbytecode(instance)
	assert(typeof(instance) == "Instance" and instance:IsA("LuaSourceContainer"), `arg #1 must be LuaSourceContainer`)

	local success, bytecode = bridge:send("get_script_bytecode", instance)
	if not success then
		return error(`Failed to get bytecode of '{instance:GetFullName()}'`, 2)
	end

	return bytecode
end

-- broken ass decompile
--function scripts.decompile(x)
--    local disassemble = script_env.loadstring(script_env.httpget("https://raw.githubusercontent.com/TheSeaweedMonster/Lua-Scripts/main/decompile.lua"))()
--    return disassemble(x)
--end

function scripts.getscripthash(instance) -- TODO Replace by sha384(getscriptbytecode(instance)) later, current impl is bad
	assert(typeof(instance) == "Instance" and instance:IsA("LuaSourceContainer"), `arg #1 must be LuaSourceContainer`)

	return if instance:IsA("Script") then instance:GetHash() else instance:GetDebugId(0)
end

function scripts.getexecutioncontext()
	local RunService = game:GetService("RunService")

	return if RunService:IsClient()
		then "Client"
		elseif RunService:IsServer() then "Server"
		else if RunService:IsStudio() then "Studio" else "Unknown"
end

function scripts.isluau()
	return _VERSION == "Luau"
end

function scripts.stringdump(func)
	local funcString = tostring(func)

	return bridge:send("python_string_dump", funcString)
end

local function deserialize(bytecode)
	local reader do
		reader = {}
		pos = 1
		function reader:pos() return pos end
		function reader:nextByte()
			local v = bytecode:byte(pos, pos)
			pos = pos + 1
			return v
		end
		function reader:nextChar()
			return string.char(reader:nextByte());
		end
		function reader:nextInt()
			local b = { reader:nextByte(), reader:nextByte(), reader:nextByte(), reader:nextByte() }
			return (
				bit32.bor(bit32.lshift(b[4], 24), 
					bit32.bor(bit32.lshift(b[3], 16),
						bit32.bor(bit32.lshift(b[2], 8),
							b[1])))
			)
		end
		function reader:nextVarInt()
			local c1, c2, b, r = 0, 0, 0, 0
			repeat
				c1 = reader:nextByte()
				c2 = bit32.band(c1, 0x7F)
				r = bit32.bor(r, bit32.lshift(c2, b))
				b = b + 7
			until not bit32.btest(c1, 0x80)
			return r;
		end
		function reader:nextString()
			local result = ""
			local len = reader:nextVarInt();
			for i = 1, len do
				result = result .. reader:nextChar();
			end
			return result;
		end
		function reader:nextDouble()
			local b = {};
			for i = 1, 8 do
				table.insert(b, reader:nextByte());
			end
			local str = '';
			for i = 1, 8 do
				str = str .. string.char(b[i]);
			end
			return string.unpack("<d", str)
		end
	end

	local bytecodeVersion = reader:nextByte()
	if (bytecodeVersion ~= 0) then
		local protoTable = {}
		local stringTable = {}

		local bytecodeEncoding = reader:nextByte()

		local sizeStrings = reader:nextVarInt()
		for i = 1,sizeStrings do
			stringTable[i] = reader:nextString()
		end

		local sizeProtos = reader:nextVarInt();
		for i = 1,sizeProtos do
			protoTable[i] = {} -- pre-initialize an entry
			protoTable[i].codeTable = {}
			protoTable[i].kTable = {}
			protoTable[i].pTable = {}
			protoTable[i].smallLineInfo = {}
			protoTable[i].largeLineInfo = {}
		end

		for i = 1,sizeProtos do
			local proto = protoTable[i]
			proto.maxStackSize = reader:nextByte()
			proto.numParams = reader:nextByte()
			proto.numUpValues = reader:nextByte()
			proto.isVarArg = reader:nextByte()

			if (bytecodeVersion >= 4) then
				proto.flags = reader:nextByte()
				proto.typeinfo = reader:nextVarInt()

				if proto.typeinfo ~= 0 then
					error'typeinfo not implemented'
				end
			end

			proto.sizeCode = reader:nextVarInt()
			for j = 1,proto.sizeCode do
				proto.codeTable[j] = reader:nextInt()
			end

			proto.sizeConsts = reader:nextVarInt();
			for j = 1,proto.sizeConsts do
				local k = {};
				k.value = nil;
				k.type = reader:nextByte();
				if k.type == 0 then -- nil
				elseif k.type == 1 then -- boolean
					k.value = (reader:nextByte() == 1 and true or false)
				elseif k.type == 2 then -- number
					k.value = reader:nextDouble()
				elseif k.type == 3 then -- string
					k.value = stringTable[reader:nextVarInt()]
				elseif k.type == 4 then -- cache
					k.value = reader:nextInt()
				elseif k.type == 5 then -- table
					k.value = { ["size"] = reader:nextVarInt(), ["ids"] = {} }
					for s = 1,k.value.size do
						table.insert(k.value.ids, reader:nextVarInt() + 1)
					end
				elseif k.type == 6 then -- closure
					k.value = reader:nextVarInt() + 1 -- closure id
				else
					error(string.format("Unrecognized constant type: %i", k.type))
				end
				proto.kTable[j] = k
			end

			proto.sizeProtos = reader:nextVarInt();
			for j = 1,proto.sizeProtos do
				proto.pTable[j] = protoTable[reader:nextVarInt() + 1]
			end

			proto.lineDefined = reader:nextVarInt()

			local protoSourceId = reader:nextVarInt()
			proto.source = stringTable[protoSourceId]

			if (reader:nextByte() == 1) then -- Has Line info?
				local compKey = reader:nextByte()
				for j = 1,proto.sizeCode do
					proto.smallLineInfo[j] = reader:nextByte()
				end

				local n = bit32.band(proto.sizeCode + 3, -4)
				local intervals = bit32.rshift(proto.sizeCode - 1, compKey) + 1

				for j = 1,intervals do
					proto.largeLineInfo[j] = reader:nextInt()
				end
			end

			if (reader:nextByte() == 1) then -- Has Debug info?
				error'debuginfo not supported'
			end
		end

		local mainProtoId = reader:nextVarInt()
		return protoTable[mainProtoId + 1], protoTable, stringTable;
	else
		error(string.format("Invalid bytecode (version: %i)", bytecodeVersion))
		return nil;
	end
end

local function getluauoptable()
	return {
		-- I could use case multiplier, but that depends only on how accurate
		-- our ordering of the opcodes are -- so if we really want to rely on
		-- the latest updated luau source, then we could do it that way.
		{ ["name"] = "NOP", ["type"] = "none", ["case"] = 0, ["number"] = 0x00 },
		{ ["name"] = "BREAK", ["type"] = "none", ["case"] = 1, ["number"] = 0xE3 },
		{ ["name"] = "LOADNIL", ["type"] = "iA", ["case"] = 2, ["number"] = 0xC6 },
		{ ["name"] = "LOADB", ["type"] = "iABC", ["case"] = 3, ["number"] = 0xA9 },
		{ ["name"] = "LOADN", ["type"] = "iABx", ["case"] = 4, ["number"] = 0x8C },
		{ ["name"] = "LOADK", ["type"] = "iABx", ["case"] = 5, ["number"] = 0x6F },
		{ ["name"] = "MOVE", ["type"] = "iAB", ["case"] = 6, ["number"] = 0x52 },
		{ ["name"] = "GETGLOBAL", ["type"] = "iAC", ["case"] = 7, ["number"] = 0x35, ["aux"] = true },
		{ ["name"] = "SETGLOBAL", ["type"] = "iAC", ["case"] = 8, ["number"] = 0x18, ["aux"] = true },
		{ ["name"] = "GETUPVAL", ["type"] = "iAB", ["case"] = 9, ["number"] = 0xFB },
		{ ["name"] = "SETUPVAL", ["type"] = "iAB", ["case"] = 10, ["number"] = 0xDE },
		{ ["name"] = "CLOSEUPVALS", ["type"] = "iA", ["case"] = 11, ["number"] = 0xC1 },
		{ ["name"] = "GETIMPORT", ["type"] = "iABx", ["case"] = 12, ["number"] = 0xA4, ["aux"] = true },
		{ ["name"] = "GETTABLE", ["type"] = "iABC", ["case"] = 13, ["number"] = 0x87 },
		{ ["name"] = "SETTABLE", ["type"] = "iABC", ["case"] = 14, ["number"] = 0x6A },
		{ ["name"] = "GETTABLEKS", ["type"] = "iABC", ["case"] = 15, ["number"] = 0x4D, ["aux"] = true },
		{ ["name"] = "SETTABLEKS", ["type"] = "iABC", ["case"] = 16, ["number"] = 0x30, ["aux"] = true },
		{ ["name"] = "GETTABLEN", ["type"] = "iABC", ["case"] = 17, ["number"] = 0x13 },
		{ ["name"] = "SETTABLEN", ["type"] = "iABC", ["case"] = 18, ["number"] = 0xF6 },
		{ ["name"] = "NEWCLOSURE", ["type"] = "iABx", ["case"] = 19, ["number"] = 0xD9 },
		{ ["name"] = "NAMECALL", ["type"] = "iABC", ["case"] = 20, ["number"] = 0xBC, ["aux"] = true },
		{ ["name"] = "CALL", ["type"] = "iABC", ["case"] = 21, ["number"] = 0x9F },
		{ ["name"] = "RETURN", ["type"] = "iAB", ["case"] = 22, ["number"] = 0x82 },
		{ ["name"] = "JUMP", ["type"] = "isBx", ["case"] = 23, ["number"] = 0x65 },
		{ ["name"] = "JUMPBACK", ["type"] = "isBx", ["case"] = 24, ["number"] = 0x48 },
		{ ["name"] = "JUMPIF", ["type"] = "iAsBx", ["case"] = 25, ["number"] = 0x2B },
		{ ["name"] = "JUMPIFNOT", ["type"] = "iAsBx", ["case"] = 26, ["number"] = 0x0E },
		{ ["name"] = "JUMPIFEQ", ["type"] = "iAsBx", ["case"] = 27, ["number"] = 0xF1, ["aux"] = true },
		{ ["name"] = "JUMPIFLE", ["type"] = "iAsBx", ["case"] = 28, ["number"] = 0xD4, ["aux"] = true },
		{ ["name"] = "JUMPIFLT", ["type"] = "iAsBx", ["case"] = 29, ["number"] = 0xB7, ["aux"] = true },
		{ ["name"] = "JUMPIFNOTEQ", ["type"] = "iAsBx", ["case"] = 30, ["number"] = 0x9A, ["aux"] = true },
		{ ["name"] = "JUMPIFNOTLE", ["type"] = "iAsBx", ["case"] = 31, ["number"] = 0x7D, ["aux"] = true },
		{ ["name"] = "JUMPIFNOTLT", ["type"] = "iAsBx", ["case"] = 32, ["number"] = 0x60, ["aux"] = true },
		{ ["name"] = "ADD", ["type"] = "iABC", ["case"] = 33, ["number"] = 0x43 },
		{ ["name"] = "SUB", ["type"] = "iABC", ["case"] = 34, ["number"] = 0x26 },
		{ ["name"] = "MUL", ["type"] = "iABC", ["case"] = 35, ["number"] = 0x09 },
		{ ["name"] = "DIV", ["type"] = "iABC", ["case"] = 36, ["number"] = 0xEC },
		{ ["name"] = "MOD", ["type"] = "iABC", ["case"] = 37, ["number"] = 0xCF },
		{ ["name"] = "POW", ["type"] = "iABC", ["case"] = 38, ["number"] = 0xB2 },
		{ ["name"] = "ADDK", ["type"] = "iABC", ["case"] = 39, ["number"] = 0x95 },
		{ ["name"] = "SUBK", ["type"] = "iABC", ["case"] = 40, ["number"] = 0x78 },
		{ ["name"] = "MULK", ["type"] = "iABC", ["case"] = 41, ["number"] = 0x5B },
		{ ["name"] = "DIVK", ["type"] = "iABC", ["case"] = 42, ["number"] = 0x3E },
		{ ["name"] = "MODK", ["type"] = "iABC", ["case"] = 43, ["number"] = 0x21 },
		{ ["name"] = "POWK", ["type"] = "iABC", ["case"] = 44, ["number"] = 0x04 },
		{ ["name"] = "AND", ["type"] = "iABC", ["case"] = 45, ["number"] = 0xE7 },
		{ ["name"] = "OR", ["type"] = "iABC", ["case"] = 46, ["number"] = 0xCA },
		{ ["name"] = "ANDK", ["type"] = "iABC", ["case"] = 47, ["number"] = 0xAD },
		{ ["name"] = "ORK", ["type"] = "iABC", ["case"] = 48, ["number"] = 0x90 },
		{ ["name"] = "CONCAT", ["type"] = "iABC", ["case"] = 49, ["number"] = 0x73 },
		{ ["name"] = "NOT", ["type"] = "iAB", ["case"] = 50, ["number"] = 0x56 },
		{ ["name"] = "UNM", ["type"] = "iAB", ["case"] = 51, ["number"] = 0x39 },
		{ ["name"] = "LEN", ["type"] = "iAB", ["case"] = 52, ["number"] = 0x1C },
		{ ["name"] = "NEWTABLE", ["type"] = "iAB", ["case"] = 53, ["number"] = 0xFF, ["aux"] = true },
		{ ["name"] = "DUPTABLE", ["type"] = "iABx", ["case"] = 54, ["number"] = 0xE2 },
		{ ["name"] = "SETLIST", ["type"] = "iABC", ["case"] = 55, ["number"] = 0xC5, ["aux"] = true },
		{ ["name"] = "NFORPREP", ["type"] = "iABx", ["case"] = 56, ["number"] = 0xA8 },
		{ ["name"] = "NFORLOOP", ["type"] = "iABx", ["case"] = 57, ["number"] = 0x8B },
		{ ["name"] = "TFORLOOP", ["type"] = "iABx", ["case"] = 58, ["number"] = 0x6E, ["aux"] = true },
		{ ["name"] = "IPAIRSPREP", ["type"] = "none", ["case"] = 59, ["number"] = 0x51 },
		{ ["name"] = "IPAIRSLOOP", ["type"] = "none", ["case"] = 60, ["number"] = 0x34 },
		{ ["name"] = "PAIRSPREP", ["type"] = "none", ["case"] = 61, ["number"] = 0x17 },
		{ ["name"] = "PAIRSLOOP", ["type"] = "none", ["case"] = 62, ["number"] = 0xFA },
		{ ["name"] = "GETVARARGS", ["type"] = "iAB", ["case"] = 63, ["number"] = 0xDD },
		{ ["name"] = "DUPCLOSURE", ["type"] = "iABx", ["case"] = 64, ["number"] = 0xC0 },
		{ ["name"] = "PREPVARARGS", ["type"] = "iA", ["case"] = 65, ["number"] = 0xA3 },
		{ ["name"] = "LOADKX", ["type"] = "iA", ["case"] = 66, ["number"] = 0x86 },
		{ ["name"] = "JUMPX", ["type"] = "isAx", ["case"] = 67, ["number"] = 0x69 },
		{ ["name"] = "FASTCALL", ["type"] = "iAC", ["case"] = 68, ["number"] = 0x4C },
		{ ["name"] = "COVERAGE", ["type"] = "isAx", ["case"] = 69, ["number"] = 0x2F },
		{ ["name"] = "CAPTURE", ["type"] = "iAB", ["case"] = 70, ["number"] = 0x12 },
		{ ["name"] = "JUMPIFEQK", ["type"] = "iABx", ["case"] = 71, ["number"] = 0xF5, ["aux"] = true  },
		{ ["name"] = "JUMPIFNOTEQK", ["type"] = "iABx", ["case"] = 72, ["number"] = 0xD8, ["aux"] = true  },
		{ ["name"] = "FASTCALL1", ["type"] = "iABC", ["case"] = 73, ["number"] = 0xBB },
		{ ["name"] = "FASTCALL2", ["type"] = "iABC", ["case"] = 74, ["number"] = 0x9E, ["aux"] = true },
		{ ["name"] = "FASTCALL2K", ["type"] = "iABC", ["case"] = 75, ["number"] = 0x81, ["aux"] = true },
		{ ["name"] = "COUNT", ["type"] = "none", ["case"] = 76, ["number"] = 0x64 }
	};
end

local luau = {};
luau.SIZE_A = 8
luau.SIZE_C = 8
luau.SIZE_B = 8
luau.SIZE_Bx = (luau.SIZE_C + luau.SIZE_B)
luau.SIZE_OP = 8
luau.POS_OP = 0
luau.POS_A = (luau.POS_OP + luau.SIZE_OP)
luau.POS_B = (luau.POS_A + luau.SIZE_A)
luau.POS_C = (luau.POS_B + luau.SIZE_B)
luau.POS_Bx = luau.POS_B
luau.MAXARG_A = (bit32.lshift(1, luau.SIZE_A) - 1)
luau.MAXARG_B = (bit32.lshift(1, luau.SIZE_B) - 1)
luau.MAXARG_C = (bit32.lshift(1, luau.SIZE_C) - 1)
luau.MAXARG_Bx = (bit32.lshift(1, luau.SIZE_Bx) - 1)
luau.MAXARG_sBx = bit32.rshift(luau.MAXARG_Bx, 1)
luau.BITRK = bit32.lshift(1, (luau.SIZE_B - 1))
luau.MAXINDEXRK = (luau.BITRK - 1)
luau.ISK = function(x) return bit32.band(x, luau.BITRK) end
luau.INDEXK = function(x) return bit32.band(x, bit32.bnot(luau.BITRK)) end
luau.RKASK = function(x) return bit32.bor(x, luau.BITRK) end
luau.MASK1 = function(n,p) return bit32.lshift(bit32.bnot(bit32.lshift(bit32.bnot(0), n)), p) end
luau.MASK0 = function(n,p) return bit32.bnot(luau.MASK1(n, p)) end
luau.GETARG_A = function(i) return bit32.band(bit32.rshift(i, luau.POS_A), luau.MASK1(luau.SIZE_A, 0)) end
luau.GETARG_B = function(i) return bit32.band(bit32.rshift(i, luau.POS_B), luau.MASK1(luau.SIZE_B, 0)) end
luau.GETARG_C = function(i) return bit32.band(bit32.rshift(i, luau.POS_C), luau.MASK1(luau.SIZE_C, 0)) end
luau.GETARG_Bx = function(i) return bit32.band(bit32.rshift(i, luau.POS_Bx), luau.MASK1(luau.SIZE_Bx, 0)) end
luau.GETARG_sBx = function(i) local Bx = luau.GETARG_Bx(i) local sBx = Bx + 1; if Bx > 0x7FFF and Bx <= 0xFFFF then sBx = -(0xFFFF - Bx); sBx = sBx - 1; end return sBx end
luau.GETARG_sAx = function(i) return bit32.rshift(i, 8) end
luau.GET_OPCODE = function(i) return bit32.band(bit32.rshift(i, luau.POS_OP), luau.MASK1(luau.SIZE_OP, 0)) end

local function disassemble(a1, showOps)
	local bcode;

	if (typeof(a1) == "Instance") then
		if not getscriptbytecode then error("Executor does not support getscriptbytecode") end
		bcode = getscriptbytecode(a1);
	elseif (type(a1) == "string") then
		bcode = a1
	end

	assert(bcode, "Failed to fetch " .. a1.ClassName .. " bytecode")

	local output = ""
	local mainProto, protoTable, stringTable = deserialize(bcode)
	local luauOpTable = getluauoptable();

	local function getOpCode(opName)
		for _,v in pairs(luauOpTable) do 
			if v.name == opName then 
				return v.number;
			end
		end
		return 0;
	end

	mainProto.source = "main"
	mainScope = {}; -- scope control, coming soon

	local function readProto(proto, depth)
		local output = "";

		local function addTabSpace(depth)
			output = output .. string.rep("    ", depth)
		end

		-- using function name (this will be removed & done outside of readProto)
		if proto.source then
			output = output .. proto.source .. " = function("
		else
			output = output .. "function("
		end

		for i = 1,proto.numParams do
			output = output .. "arg" .. (i - 1) -- args coincide with stack index
			if i < proto.numParams then
				output = output .. ", "
			end
		end

		if proto.isVarArg ~= 0 then
			if proto.numParams > 0 then
				output = output .. ", "
			end
			output = output .. "..."
		end

		output = output .. ")\n"

		depth = depth + 1

		for i = 1,proto.numParams do
			addTabSpace(depth);
			output = output .. string.format("local var%i = arg%i\n", i - 1, i - 1);
		end

		local refData = {}
		local nameCall = nil
		local markedAux = false
		local codeIndex = 1
		while codeIndex < proto.sizeCode do
			local i = proto.codeTable[codeIndex]
			local opc = luau.GET_OPCODE(i)
			local A = luau.GETARG_A(i)
			local B = luau.GETARG_B(i)
			local Bx = luau.GETARG_Bx(i)
			local C = luau.GETARG_C(i)
			local sBx = luau.GETARG_sBx(i)
			local sAx = luau.GETARG_sAx(i)
			local aux = proto.codeTable[codeIndex + 1]

			if markedAux then
				markedAux = false
			else
				addTabSpace(depth);

				local opinfo;

				for _,v in pairs(luauOpTable) do 
					if v.number == opc then 
						opinfo = v
						break;
					end
				end

				output = output .. tostring(codeIndex) .. ".   " 

				if showOps and opinfo then
					local str = opinfo.name .. string.rep(" ", 16 - string.len(opinfo.name))

					if opinfo.type == "iA" then
						str = str .. string.format("%i", A)
					elseif opinfo.type == "iAB" then
						str = str .. string.format("%i %i", A, B)
					elseif opinfo.type == "iAC" then
						str = str .. string.format("%i %i", A, C)
					elseif opinfo.type == "iABx" then
						str = str .. string.format("%i %i", A, Bx)
					elseif opinfo.type == "iAsBx" then
						str = str .. string.format("%i %i", A, sBx)
					elseif opinfo.type == "isBx" then
						str = str .. string.format("%i", sBx)
					elseif opinfo.type == "iABC" then
						str = str .. string.format("%i %i %i", A, B, C)
					end

					if opinfo.aux then
						str = str .. " [aux]";
						markedAux = true
					end

					output = output .. str .. string.rep(" ", 40 - string.len(str))
				else
					if opinfo then
						if opinfo.aux then
							markedAux = true;
						end
					end
				end

				-- continue with disassembly (rough decompilation -- no scope/flow control)
				-- 
				local varsDefined = {};

				local function defineVar(index, name)
					table.insert(varsDefined, { ["name"] = name, ["stackIndex"] = index });
				end

				local function isVarDefined(index)
					return true;
                    --[[for _,v in pairs(varsDefined) do
                        if v.stackIndex == index then
                            return true
                        end
                    end
                    return false;
                    ]]
				end

				local function addReference(refStart, refEnd)
					for _,v in pairs(refData) do
						if v.codeIndex == refEnd then
							table.insert(v.refs, refStart);
							return;
						end
					end
					table.insert(refData, { ["codeIndex"] = refEnd, ["refs"] = { refStart } });
				end

				local nilValue = { ["type"] = "nil", ["value"] = "nil" }


                --[[ TO-DO: we could make getOpCode faster by using the opcode
                numbers directly, or just getting it by table index and the 
                case-to-opcode multiplier (op * 227)
                but tbh this runs just fine
                ]]
				if opc == getOpCode("LOADNIL") then
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = nil", A)
				elseif opc == getOpCode("BREAK") then
					output = output .. "break"
				elseif opc == getOpCode("LOADK") then
					local k = proto.kTable[Bx + 1] or nilValue;
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = %s", A, (type(k.value) == "string") and ("\"" .. k.value .. "\"") or tostring(k.value))
				elseif opc == getOpCode("LOADKX") then
					local k = proto.kTable[aux + 1] or nilValue;
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = %s", A, (type(k.value) == "string") and ("\"" .. k.value .. "\"") or tostring(k.value))
				elseif opc == getOpCode("LOADB") then
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = %s", A, tostring(B == 1))
				elseif opc == getOpCode("LOADN") then
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = %s", A, tostring(Bx))
				elseif opc == getOpCode("GETUPVAL") then
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = upvalues[%i]", A, B)
				elseif opc == getOpCode("SETUPVAL") then
					output = output .. string.format("upvalues[%i] = var%i", B, A)
				elseif opc == getOpCode("MOVE") then
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = var%i", A, B)
				elseif opc == getOpCode("LEN") then
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = #var%i", A, B)
				elseif opc == getOpCode("UNM") then
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = -var%i", A, B)
				elseif opc == getOpCode("NOT") then
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = not var%i", A, B)
				elseif opc == getOpCode("GETVARARGS") then
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = ...", A)
				elseif opc == getOpCode("CONCAT") then
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = var%i .. var%i", A, B, C)
				elseif opc == getOpCode("AND") then
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = var%i and var%i", A, B, C)
				elseif opc == getOpCode("OR") then
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = var%i or var%i", A, B, C)
				elseif opc == getOpCode("ANDK") then
					local k = proto.kTable[C + 1] or nilValue;
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = var%i and %s", A, B, tostring(k.value))
				elseif opc == getOpCode("ORK") then
					local k = proto.kTable[C + 1] or nilValue;
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = var%i or %s", A, B, tostring(k.value))
				elseif opc == getOpCode("FASTCALL") then
					output = output .. string.format("FASTCALL[id=%i]()", A, B);
				elseif opc == getOpCode("FASTCALL2") then
					output = output .. string.format("FASTCALL[id=%i]()", A, B);
				elseif opc == getOpCode("FASTCALL2K") then
					output = output .. string.format("FASTCALL[id=%i]()", A, B);
				elseif opc == getOpCode("GETIMPORT") then
					local indexCount = bit32.band(bit32.rshift(aux, 30), 0x3FF) -- 0x40000000 --> 1, 0x80000000 --> 2
					local cacheIndex1 = bit32.band(bit32.rshift(aux, 20), 0x3FF)
					local cacheIndex2 = bit32.band(bit32.rshift(aux, 10), 0x3FF)
					local cacheIndex3 = bit32.band(bit32.rshift(aux, 0), 0x3FF)

					if indexCount == 1 then
						local k1 = proto.kTable[cacheIndex1 + 1];

						output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = %s", A, tostring(k1.value))
					elseif indexCount == 2 then
						local k1 = proto.kTable[cacheIndex1 + 1];
						local k2 = proto.kTable[cacheIndex2 + 1];

						output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = %s[\"%s\"]", A, k1.value, tostring(k2.value))
					elseif indexCount == 3 then
						local k1 = proto.kTable[cacheIndex1 + 1];
						local k2 = proto.kTable[cacheIndex2 + 1];
						local k3 = proto.kTable[cacheIndex3 + 1];

						output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = %s[\"%s\"][\"%s\"]", A, k1.value, tostring(k2.value), tostring(k3.value))
					else
						error("[GETIMPORT] Too many entries");
					end
				elseif opc == getOpCode("GETGLOBAL") then
					local k = proto.kTable[aux + 1] or nilValue;
					output = output .. string.format("var%i = %s", A, tostring(k.value))
				elseif opc == getOpCode("SETGLOBAL") then
					local k = proto.kTable[aux + 1] or nilValue;
					output = output .. string.format("%s = var%i", tostring(k.value), A)
				elseif opc == getOpCode("GETTABLE") then
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = var%i[var%i]", A, B, C)
				elseif opc == getOpCode("SETTABLE") then
					output = output .. string.format("var%i[var%i] = var%i", B, C, A)
				elseif opc == getOpCode("GETTABLEN") then
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = var%i[%i]", A, B, C - 1)
				elseif opc == getOpCode("SETTABLEN") then
					output = output .. string.format("var%i[%i] = var%i", B, C - 1, A)
				elseif opc == getOpCode("GETTABLEKS") then
					local k = proto.kTable[aux + 1] or nilValue;
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = var%i[%s]", A, B, (type(k.value) == "string") and ("\"" .. k.value .. "\"") or tostring(k.value))
				elseif opc == getOpCode("SETTABLEKS") then
					local k = proto.kTable[aux + 1] or nilValue;
					output = output .. string.format("var%i[%s] = var%i", B, (type(k.value) == "string") and ("\"" .. k.value .. "\"") or tostring(k.value), A)
				elseif opc == getOpCode("NAMECALL") then
					local k = proto.kTable[aux + 1] or nilValue;
					nameCall = string.format("var%i:%s", B, tostring(k.value))
					markedAux = true;
				elseif opc == getOpCode("NFORPREP") then
					output = output .. string.format("nforprep start - [escape at #%i] -- var%i = iterator", (codeIndex + sBx) + 1, A + 3);
				elseif opc == getOpCode("NFORLOOP") then
					output = output .. string.format("nforloop end - iterate + goto #%i", codeIndex + sBx);
				elseif opc == getOpCode("PAIRSPREP") then
					output = output .. string.format("pairsprep start - [escape at #%i] -- var%i = key, var%i = value", (codeIndex + sBx) + 1, A + 3, A + 4);
				elseif opc == getOpCode("PAIRSLOOP") then
					output = output .. string.format("pairsloop end - iterate + goto #%i", codeIndex + sBx);
				elseif opc == getOpCode("IPAIRSPREP") then
					output = output .. string.format("ipairsprep start [escape at #%i] -- var%i = key, var%i = value", (codeIndex + sBx) + 1, A + 3, A + 4);
				elseif opc == getOpCode("IPAIRSLOOP") then
					output = output .. string.format("ipairsloop end - iterate + goto #%i", codeIndex + sBx);
				elseif opc == getOpCode("TFORLOOP") then
					output = output .. string.format("gforloop - iterate + goto #%i", codeIndex + aux);
				elseif opc == getOpCode("JUMP") then
					addReference(codeIndex, codeIndex + sBx);
					output = output .. string.format("goto #%i", codeIndex + sBx);
				elseif opc == getOpCode("JUMPBACK") then
					addReference(codeIndex, codeIndex + sBx);
					output = output .. string.format("goto #%i", codeIndex + sBx);
				elseif opc == getOpCode("JUMPX") then
					addReference(codeIndex, codeIndex + sBx);
					output = output .. string.format("goto #%i", codeIndex + sAx);
				elseif opc == getOpCode("JUMPIFEQK") then
					local k = proto.kTable[aux + 1] or nilValue;
					addReference(codeIndex, codeIndex + sBx);
					output = output .. string.format("goto #%i if var%i == %s", codeIndex + sBx, A, (type(k.value) == "string") and ("\"" .. k.value .. "\"") or tostring(k.value));
				elseif opc == getOpCode("JUMPIFNOTEQK") then
					local k = proto.kTable[aux + 1] or nilValue;
					addReference(codeIndex, codeIndex + sBx);
					output = output .. string.format("goto #%i if var%i ~= %s", codeIndex + sBx, A, (type(k.value) == "string") and ("\"" .. k.value .. "\"") or tostring(k.value));
				elseif opc == getOpCode("JUMPIF") then
					addReference(codeIndex, codeIndex + sBx);
					output = output .. string.format("goto #%i if var%i", codeIndex + sBx, A);
				elseif opc == getOpCode("JUMPIFNOT") then
					addReference(codeIndex, codeIndex + sBx);
					output = output .. string.format("goto #%i if not var%i", codeIndex + sBx, A);
				elseif opc == getOpCode("JUMPIFEQ") then
					addReference(codeIndex, codeIndex + sBx);
					output = output .. string.format("goto #%i if var%i == var%i", codeIndex + sBx, A, aux);
				elseif opc == getOpCode("JUMPIFNOTEQ") then
					addReference(codeIndex, codeIndex + sBx);
					output = output .. string.format("goto #%i if var%i ~= var%i", codeIndex + sBx, A, aux);
				elseif opc == getOpCode("JUMPIFLE") then
					addReference(codeIndex, codeIndex + sBx);
					output = output .. string.format("goto #%i if var%i <= var%i", codeIndex + sBx, A, aux);
				elseif opc == getOpCode("JUMPIFNOTLE") then
					addReference(codeIndex, codeIndex + sBx);
					output = output .. string.format("goto #%i if var%i > var%i", codeIndex + sBx, A, aux);
				elseif opc == getOpCode("JUMPIFLT") then
					addReference(codeIndex, codeIndex + sBx);
					output = output .. string.format("goto #%i if var%i < var%i", codeIndex + sBx, A, aux);
				elseif opc == getOpCode("JUMPIFNOTLT") then
					addReference(codeIndex, codeIndex + sBx);
					output = output .. string.format("goto #%i if var%i >= var%i", codeIndex + sBx, A, aux);
				elseif opc == getOpCode("ADD") then
					output = output .. string.format("var%i = var%i + var%i", A, B, C);
				elseif opc == getOpCode("ADDK") then
					local k = proto.kTable[C + 1] or nilValue;
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = var%i + %s", A, B, tostring(k.value));
				elseif opc == getOpCode("SUB") then
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = var%i - var%i", A, B, C);
				elseif opc == getOpCode("SUBK") then
					local k = proto.kTable[C + 1] or nilValue;
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = var%i - %s", A, B, tostring(k.value));
				elseif opc == getOpCode("MUL") then
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = var%i * var%i", A, B, C);
				elseif opc == getOpCode("MULK") then
					local k = proto.kTable[C + 1] or nilValue;
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = var%i * %s", A, B, tostring(k.value));
				elseif opc == getOpCode("DIV") then
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = var%i / var%i", A, B, C);
				elseif opc == getOpCode("DIVK") then
					local k = proto.kTable[C + 1] or nilValue;
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = var%i / %s", A, B, tostring(k.value));
				elseif opc == getOpCode("MOD") then
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = var%i %% var%i", A, B, C);
				elseif opc == getOpCode("MODK") then
					local k = proto.kTable[C + 1] or nilValue;
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = var%i %% %s", A, B, tostring(k.value));
				elseif opc == getOpCode("POW") then
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = var%i ^ var%i", A, B, C);
				elseif opc == getOpCode("POWK") then
					local k = proto.kTable[C + 1] or nilValue;
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = var%i ^ %s", A, B, tostring(k.value));
				elseif opc == getOpCode("CALL") then
					if C > 1 then
						for j = 1, C - 1 do
							output = output .. string.format("var%i", A + j - 1)
							if j < C - 1 then output = output .. ", " end
						end
						output = output .. " = "
					elseif C == 0 then
						output = output .. string.format("var%i, ...", A);
						output = output .. " = "
						--for j = 1, proto.maxStackSize do
						--    output = output .. string.format("var%i", A + j - 1)
						--    if j < proto.maxStackSize - 1 then output = output .. ", " end
						--end
					end
					if nameCall then
						output = output .. nameCall .. "(";
					else
						output = output .. string.format("var%i(", A)
					end
					if B > 1 then
						if nameCall then
							for j = 1, B - 2 do
								output = output .. string.format("var%i", A + 1 + j) -- exclude self
								if j < B - 2 then output = output .. ", " end
							end
						else
							for j = 1, B - 1 do
								output = output .. string.format("var%i", A + j)
								if j < B - 1 then output = output .. ", " end
							end
						end
					elseif B == 0 then
						output = output .. string.format("var%i, ...", A + 1);
						--for j = 1, proto.maxStackSize do
						--    if nameCall then
						--        output = output .. string.format("var%i", A + 1 + j) -- exclude self
						--    else
						--        output = output .. string.format("var%i", A + j)
						--    end
						--    if j < proto.maxStackSize - 1 then output = output .. ", " end
						--end
					end
					nameCall = nil;
					output = output .. ")";
				elseif opc == getOpCode("NEWTABLE") then
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = {}", A)
				elseif opc == getOpCode("DUPTABLE") then
					local t = proto.kTable[Bx + 1].value;
					output = output .. (isVarDefined(A) and "" or "local ") .. string.format("var%i = { ", A)
					for j = 1,t.size do
						local id = t.ids[j];
						local k = proto.kTable[id];
						output = output .. ((type(k.value) == "string") and ("\"" .. k.value .. "\"") or tostring(k.value))
						if j < t.size then
							output = output .. ", ";
						end
					end
					output = output .. "}";
				elseif opc == getOpCode("SETLIST") then
					local fieldSize = aux;
					output = output .. "\n"
					for j = 1, C do
						addTabSpace(depth);
						output = output .. string.format("var%i[%i] = var%i\n", A, j + fieldSize - 1, B + j - 1);
					end
				elseif opc == getOpCode("CAPTURE") then
					markedAux = true;
				elseif opc == getOpCode("NEWCLOSURE") then
					output = output .. "\n"

					local nCaptures = 0;
					for j = codeIndex + 1, proto.sizeCode do
						if luau.GET_OPCODE(proto.codeTable[j]) ~= getOpCode("CAPTURE") then
							break
						else
							local upvalueIndex = j - codeIndex - 1;
							local captureType = luau.GETARG_A(proto.codeTable[j]);
							local captureIndex = luau.GETARG_Bx(proto.codeTable[j]);

							nCaptures = nCaptures + 1;

							addTabSpace(depth);
							if captureType == 0 or captureType == 1 then
								output = output .. string.format("-- V nested upvalues[%i] = var%i\n", upvalueIndex, captureIndex)
							elseif captureType == 2 then
								output = output .. string.format("-- V nested upvalues[%i] = upvalues[%i]\n", upvalueIndex, captureIndex)
							else
								error("[NEWCLOSURE] Invalid capture type");
							end
						end
					end
					codeIndex = codeIndex + nCaptures;

					addTabSpace(depth);
					local nextProto = proto.pTable[Bx + 1]
					if nextProto.source then
						output = output .. readProto(nextProto, depth)
						addTabSpace(depth);
						output = output .. string.format("var%i = ", A) .. nextProto.source
					else
						nextProto.source = nil;
						output = output .. string.format("var%i = ", A) .. readProto(nextProto, depth)
					end
				elseif opc == getOpCode("DUPCLOSURE") then
					output = output .. "\n"

					local nCaptures = 0;
					for j = codeIndex + 1, proto.sizeCode do
						if luau.GET_OPCODE(proto.codeTable[j]) ~= getOpCode("CAPTURE") then
							break
						else
							local upvalueIndex = j - codeIndex - 1;
							local captureType = luau.GETARG_A(proto.codeTable[j]);
							local captureIndex = luau.GETARG_Bx(proto.codeTable[j]);

							nCaptures = nCaptures + 1;

							addTabSpace(depth);
							if captureType == 0 or captureType == 1 then
								output = output .. string.format("-- V nested upvalues[%i] = var%i\n", upvalueIndex, captureIndex)
							elseif captureType == 2 then
								output = output .. string.format("-- V nested upvalues[%i] = upvalues[%i]\n", upvalueIndex, captureIndex)
							else
								error("[DUPCLOSURE] Invalid capture type");
							end
						end
					end
					codeIndex = codeIndex + nCaptures;

					addTabSpace(depth);
					local nextProto = protoTable[proto.kTable[Bx + 1].value]
					if nextProto.source then
						output = output .. readProto(nextProto, depth)
						addTabSpace(depth);
						output = output .. string.format("var%i = ", A) .. nextProto.source
					else
						nextProto.source = nil;
						output = output .. string.format("var%i = ", A) .. readProto(nextProto, depth)
					end
				elseif opc == getOpCode("RETURN") then
					if B > 1 then
						output = output .. "return ";
						for j = 1, B - 1 do
							output = output .. string.format("var%i", A + j)
							if j < B - 1 then output = output .. ", " end
						end
					elseif B == 0 then
						output = output .. string.format("var%i, ...", A)
					end
				end

				for _,v in pairs(refData) do
					if v.codeIndex == codeIndex then
						output = output .. " -- referenced by "
						for j = 1,#v.refs do
							output = output .. "#" .. v.refs[j]
							if j < #v.refs then
								output = output .. ", "
							end
						end
					end
				end

				output = output .. "\n"
			end

			codeIndex = codeIndex + 1
		end

		depth = depth - 1

		addTabSpace(depth)
		output = output .. "end\n"
		return output;
	end

	local startDepth = 0;
	output = output .. readProto(mainProto, startDepth)

	return output
end

local rconsole = {}

function rconsole.rconsolecreate()
	bridge:send("console_create")
	return true
end
function rconsole.rconsoledestroy()
	bridge:send("console_destroy")
	return true
end


function rconsole.rconsoleprint(msg)
	bridge:send("console_print")
	return true
end

function rconsole.rconsoleinfo(msg)
	bridge:send("console_info")
	return true
end

function rconsole.rconsolewarn(msg)
	bridge:send("console_warn")
	return true
end

function rconsole.rconsoleerr(msg)
	bridge:send("console_error")
	return true
end


function rconsole.rconsoleinput()
	local _success, result = bridge:send("console_input")

	return result
end


function rconsole.rconsoleclear()
	bridge:send("console_clear")
	return true
end

function rconsole.rconsolesettitle(title)
	bridge:send("console_title", title)
	return true
end

script_env = {}

-- main
local misc = {}

misc.isreadonly = table.isfrozen

function misc.setreadonly(t, lock)
	if table.isfrozen(t) then
		if lock then
			return
		end
	else
		if not lock then
			return
		end
		table.freeze(t)
	end
end

function misc.identifyexecutor()
	return "${EXEC_AUTOMATIC}", "${VERSION_AUTOMATIC}"
end

function misc.setclipboard(to_copy)
	assert(type(to_copy) == "string", `arg #1 must be type string`)
	assert(to_copy ~= "", `arg #1 cannot be empty`)

	local clipboard_success = bridge:send("set_clipboard", to_copy)

	if not clipboard_success then
		return error("Can't set to clipboard", 2)
	end
	return clipboard_success
end

function misc.getobjects(assetid)
	if type(assetid) == "number" then
		assetid = "rbxassetid://" .. assetid
	end
	return { game:GetService("InsertService"):LoadLocalAsset(assetid) }
end

function misc.getcustomasset(path)
	assert(path ~= "", `arg #1 cannot be empty`)
	assert(type(path) == "string", `arg #1 must be type string`)

	local backslashed_path = string.gsub(path, "/", "\\")
	local success, asset_url = bridge:send("get_custom_asset", backslashed_path)

	if not success then
		return error(`Failed to get asset URL of '{path}'`, 2)
	end
	return asset_url
end

function misc.messagebox(text, caption, flags)
	assert(type(text) == "string", `arg #1 must be type string`)
	assert(text ~= "", `arg #1 cannot be empty`)
	assert(type(caption) == "string", `arg #2 must be type string`)
	assert(caption ~= "", `arg #2 cannot be empty`)
	if flags ~= nil then
		assert(type(flags) == "number", `arg #3 should be a number`)
	end

	local _success, result = bridge:send("messagebox", text, caption, flags or 1)

	return result
end

function misc.gethwid()
	local success, hwid = bridge:send("get_hwid")
	if not success then
		return error("Failed to get HWID", 2)
	end
	return hwid
end

function misc.getfflag(flag)
	assert(type(flag) == "string", "arg #1 must be type string")
	assert(flag ~= "", `arg #1 cannot be empty`)

	for container, methods in
		{ [game] = { "GetFastFlag", "GetFastString", "GetFastInt" }, [settings()] = { "GetFFlag", "GetFVariable" } }
	do
		for _, method in methods do
			local s, r = pcall(container[method], container, flag)
			if s then
				return r
			end
		end
	end
end

do -- TODO Should be able to uncap
	local RunService = game:GetService("RunService")
	local Capped, FractionOfASecond
	local Heartbeat = RunService.Heartbeat
	function misc.setfpscap(fps_cap)
		if fps_cap == 0 or fps_cap == nil or 1e4 <= fps_cap then -- ~7k fps is the highest people have gotten; --?maybe compare to getfpsmax instead? (but we have to ensure getfpsmax is accurate first)
			if Capped then
				task.cancel(Capped)
				Capped = nil
				FractionOfASecond = nil
			end
			return
		end

		FractionOfASecond = 1 / fps_cap
		if Capped then
			return
		end
		local function Capper()
			-- * Modified version of https://github.com/MaximumADHD/Super-Nostalgia-Zone/blob/540221bc945a8fc3a45baf51b40e02272a21329d/Client/FpsCap.client.lua#
			local t0 = os.clock()
			Heartbeat:Wait()
			-- repeat until t0 + t1 < tick()
			-- local count = 0
			while os.clock() <= t0 + FractionOfASecond do -- * not using repeat to avoid unreasonable extra iterations
				-- count+=1
			end
			-- task.spawn(print,count)
		end
		Capper() -- Yield until it kicks in basically
		Capped = task.spawn(function()
			-- capping = true -- * this works too
			while true do
				Capper()
			end
		end)
	end
end

misc.getgc = function()
	local function scanTable(t, scanned)
		if scanned[t] then return end
		scanned[t] = true

		for k, v in pairs(t) do
			if type(v) == "table" then
				scanTable(v, scanned)
			end
		end
	end

	local scanned = {}
	local results = {}

	scanTable(_G, scanned)

	for t in pairs(scanned) do
		table.insert(results, t)
	end

	return results
end

function misc.hookfunction(old, new, run_on_separate_thread)
	local function createMetahook(hookFunction)
		return setmetatable({}, {
			__call = function(_, ...)
				hookFunction()
				return createMetahook(hookFunction)
			end
		})
	end

	local function hookFunction(oldFunc, newFunc, runOnSeparateThread)
		local oldEnv = getfenv(oldFunc)
		local newEnv = createMetahook(function()
			if newFunc then
				if runOnSeparateThread then
					task.spawn(function() pcall(newFunc) end)
				else
					pcall(newFunc)
				end
			end
		end)

		for k, v in pairs(oldEnv) do
			rawset(newEnv, k, v)
		end

		setfenv(oldFunc, newEnv)

		return function(...)
			local originalEnv = getfenv(oldFunc)
			local result = { setfenv(oldFunc, oldEnv)(...) }
			setfenv(oldFunc, newEnv)
			return table.unpack(result)
		end
	end

	local isJammable, errorMessage = pcall(function() setfenv(old, getfenv(old)) end)

	if not isJammable then
		local name = debug.getinfo(old, "n").name
		if getfenv(old)[name] == old then
			getfenv(old)[name] = new
		else
			error("Unable to hook local C closures", 0)
		end
	else
		return hookFunction(old, new, run_on_separate_thread)
	end
end

--function misc.hookfunction(old, new, run_on_seperate_thread)
--    local Metatable_library = {
--        metamethods = {
--            __index = function(self, key)
--                return self[key]
--            end,
--            __newindex = function(self, key, value)
--                self[key] = value
--            end,
--            __call = function(self, ...)
--                return self(...)
--            end,
--        }
--    }

--    function Metatable_library.metahook(t, f)
--        local metahook = {
--            __metatable = getmetatable(t) or "The metatable is locked"
--        }

--        for metamethod, value in pairs(Metatable_library.metamethods) do
--            metahook[metamethod] = function(self, ...)
--                f()
--                return Metatable_library.metahook({}, f)
--            end
--        end

--        return setmetatable({}, metahook)
--    end

--    local is_jammable = pcall(setfenv, old, getfenv(old))

--    if not is_jammable then
--        local name = debug.getinfo(old, "n").name

--        if getfenv(old)[name] == old then
--            getfenv(old)[name] = new
--        else
--            error("Unable to hook local C closures", 0)
--        end
--    else
--        local old_environment = getfenv(old)
--        
--        local last_line = -1
--        local last_source = function() end
--        
--        local debug_info = debug.getinfo
--        local hook = Metatable_library.metahook(getfenv(old), function()
--            local line, source = debug_info(4, "ls")

--            if line ~= last_line or last_source ~= last_source then
--                if new then
--                    if run_on_seperate_thread then
--                        task.spawn(function()
--                            pcall(function()
--                                coroutine.wrap(pcall)(new)
--                            end)
--                        end)
--                    else
--                        new()
--                    end
--                end

--                last_line = line
--                last_source = source
--            end
--        end)

--        for i, v in pairs(old_environment) do
--            rawset(hook, i, v)
--        end

--        setfenv(old, hook)

--        return function(...)
--            local return_value = {setfenv(old, old_environment)(...)}
--            setfenv(old, hook)

--            return unpack(return_value)
--        end
--    end
--end




-- Cache lib

misc.cache = {}
cache = {}

function misc.cache.iscached(thing)
	if not thing.Parent then
		return cache[thing] ~= 'REMOVE'
	else
		return false
	end
end

function misc.cache.invalidate(thing)
	cache[thing] = 'REMOVE'
	thing.Parent = nil
end

function misc.cache.replace(a, b)
	if cache[a] then
		cache[a] = b
	end
end

do -- Websockets
	local WebSocket = { connect = nil }

	local websocket_mt = {
		__index = function(self, index)
			if not rawget(self, "__OBJECT_ACTIVE") then
				error("WebSocket is closed.")
			end

			if index == "OnMessage" then
				if not rawget(self, "__OBJECT_ACTIVE") then
					error("WebSocket is closed.")
				end

				return rawget(self, "__OBJECT_MESSAGE")
			end

			if index == "OnClose" then
				if not rawget(self, "__OBJECT_ACTIVE") then
					error("WebSocket is closed.")
				end

				return rawget(self, "__OBJECT_CLOSE")
			end

			if index == "Send" then
				return function(_, message, is_binary)
					if not rawget(self, "__OBJECT_ACTIVE") then
						error("WebSocket is closed.")
					end

					bridge:send("websocket_send", rawget(self, "__OBJECT"), message, is_binary)
				end
			end

			if index == "Close" then
				return function(_)
					if not rawget(self, "__OBJECT_ACTIVE") then
						error("WebSocket is closed.")
					end
					rawset(self, "__OBJECT_ACTIVE", false)

					bridge:send("websocket_close", rawget(self, "__OBJECT"))
				end
			end
		end,
		__newindex = function()
			error("WebSocket is readonly.")
		end,
		__type = "WebSocket",
	}

	function WebSocket.connect(url: string)
		-- TODO: This might break (mix up) if called quickly within a short time span

		local success = bridge:send("websocket_connect", url)
		if not success then
			error("Failed to start/connect WebSocket server", 2)
		end

		local websocket_connection = setmetatable({
			ClassName = "WebSocket",
			__OBJECT = url,
			__OBJECT_ACTIVE = true,
			__OBJECT_MESSAGE = goodsignal.new(),
			__OBJECT_CLOSE = goodsignal.new(),
		}, websocket_mt)

		websocket_connection.__OBJECT_CLOSE:Connect(function()
			websocket_connection.__OBJECT_ACTIVE = false
		end)

		game:GetService("Players").LocalPlayer.OnTeleport:Connect(function(teleportState)
			if teleportState == Enum.TeleportState.Started and websocket_connection.__OBJECT_ACTIVE then
				websocket_connection:Close()
			end
		end)

		bridge:register_callback(url .. "_message", function(...)
			websocket_connection.__OBJECT_MESSAGE:Fire(...)
		end)

		bridge:register_callback(url .. "_close", function(...)
			websocket_connection.__OBJECT_CLOSE:Fire(...)
		end)

		return websocket_connection
	end

	misc.WebSocket = WebSocket
end

function misc.lrm_load_script(script_id)
	local code = [[

ce_like_loadstring_fn = loadstring;
loadstring = nil;

]] .. script_env.httpget("https://api.luarmor.net/files/v3/l/" .. script_id .. ".lua")
	return script_env.loadstring(code)({ Origin = "Savage" })
end

--https://github.com/MaximumADHD/Roblox-Client-Tracker/tree/roblox/LuaPackages/Packages/_Index/Rhodium/Rhodium/InputTypes
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = Instance.new("VirtualInputManager")

local input, alias =
	{}, {
		["isrbxactive"] = { "isgameactive", "iswindowactive" },
		["keyclick"] = { "hitkey" },
	}

do -- IsFocused
	local window_focused = true -- TODO Find a better way instead of Assuming (Maybe we could force focus)

	UserInputService.WindowFocusReleased:Connect(function()
		window_focused = false
	end)
	UserInputService.WindowFocused:Connect(function()
		window_focused = true
	end)

	function input.isrbxactive()
		return window_focused
	end
end

-- QuotedDouble Hash Dollar Percent Ampersand LeftParenthesis RightParenthesis Asterisk Underscore Tilde Colon Plus Pipe LessThan GreaterThan Question At Caret LeftCurly RightCurly are all deprecated

-- basic virtual key code -> roblox KeyCode map (for backwards compatibility)
-- https://docs.microsoft.com/en-us/windows/desktop/inputdev/virtual-key-codes
-- https://developer.roblox.com/api-reference/enum/KeyCode

--[[ --TODO Map these to mouse functions?

VK_LBUTTON 	0x01 	Left mouse button
VK_RBUTTON 	0x02 	Right mouse button

VK_MBUTTON 	0x04 	Middle mouse button
VK_XBUTTON1 	0x05 	X1 mouse button
VK_XBUTTON2 	0x06 	X2 mouse button

]]

local map = {
	-- [0x03] = Enum.KeyCode.LeftControl + Enum.KeyCode.Break

	[0x10] = Enum.KeyCode.LeftShift, -- Ambiguation Shift
	[0x11] = Enum.KeyCode.LeftControl, -- Ambiguation Ctrl
	[0x12] = Enum.KeyCode.LeftAlt, -- Ambiguation Alt

	-- TODO These need to only appear once (it will be a problem if we move some keycode from beginning to end, currently we only need to do the opposite luckily)
	[0x14] = Enum.KeyCode.CapsLock,

	[0x1F] = Enum.KeyCode.Mode,

	[0x21] = Enum.KeyCode.PageUp,
	[0x22] = Enum.KeyCode.PageDown,
	[0x23] = Enum.KeyCode.End,
	[0x24] = Enum.KeyCode.Home,
	[0x25] = Enum.KeyCode.Left,
	[0x26] = Enum.KeyCode.Up,
	[0x27] = Enum.KeyCode.Right,
	[0x28] = Enum.KeyCode.Down,
	[0x29] = false,
	[0x2A] = Enum.KeyCode.Print, -- Not sure
	[0x2B] = false,
	[0x2C] = Enum.KeyCode.Print,
	[0x2D] = Enum.KeyCode.Insert,
	[0x2E] = Enum.KeyCode.Delete,
	[0x2F] = Enum.KeyCode.Help,

	[0x5B] = Enum.KeyCode.LeftSuper,
	[0x5C] = Enum.KeyCode.RightSuper,
	[0x5D] = Enum.KeyCode.Menu, -- Not sure
	[0x5E] = false,
	[0x5F] = false,

	[0x6A] = Enum.KeyCode.KeypadMultiply,
	[0x6B] = Enum.KeyCode.KeypadPlus,
	[0x6C] = false,
	[0x6D] = Enum.KeyCode.KeypadMinus,
	[0x6E] = Enum.KeyCode.KeypadPeriod,
	[0x6F] = Enum.KeyCode.KeypadDivide,

	[0x7F] = false,

	[0x90] = Enum.KeyCode.NumLock,
	[0x91] = Enum.KeyCode.ScrollLock,

	[0xA0] = Enum.KeyCode.LeftShift,
	[0xA1] = Enum.KeyCode.RightShift,
	[0xA2] = Enum.KeyCode.LeftControl,
	[0xA3] = Enum.KeyCode.RightControl,
	[0xA4] = Enum.KeyCode.LeftAlt,
	[0xA5] = Enum.KeyCode.RightAlt,

	[0xBA] = Enum.KeyCode.Semicolon,
	[0xBB] = Enum.KeyCode.Plus,
	[0xBC] = Enum.KeyCode.Comma,
	[0xBD] = Enum.KeyCode.Minus,
	[0xBE] = Enum.KeyCode.Period,
	[0xBF] = Enum.KeyCode.Slash,

	[0xC0] = Enum.KeyCode.Backquote,

	[0xDB] = Enum.KeyCode.LeftBracket,
	[0xDC] = Enum.KeyCode.BackSlash,
	[0xDD] = Enum.KeyCode.RightBracket,
	[0xDE] = Enum.KeyCode.Quote,

	[0xE2] = Enum.KeyCode.LessThan,

	[0xFE] = Enum.KeyCode.Clear, -- Not sure
}
do -- Map Virtual Keys to KeyCode Enum
	local function virtual_to_keycode(value)
		for i, v in Enum.KeyCode:GetEnumItems() do
			if v.Value == value then
				return v
			end
		end
	end
	-- Re-Map
	for i = 0, 25 do
		map[i + 0x41] = virtual_to_keycode(i + 97)
	end -- A-Z
	for i = 0, 9 do
		map[i + 0x60] = virtual_to_keycode(i + 256)
	end -- Keypad 0-9
	for i = 0, 14 do
		map[i + 0x70] = virtual_to_keycode(i + 282)
	end -- Function 1-15

	for i, v in Enum.KeyCode:GetEnumItems() do -- ? Maybe blacklist Enum's containing "World" in the name
		local Override = map[v.Value]

		if Override == nil then
			if string.find(v.Name, "World", nil, true) then
				continue
			end
			map[v.Value] = v
		elseif Override == false then
			map[v.Value] = nil
		end
	end
end

do -- Keyboard
	local function get_keycode(key)
		local Type = typeof(key)
		if Type ~= "EnumItem" then
			if Type == "string" then
				key = tonumber(key)
			end
			key = map[key]
			assert(key, "Unable to map key to Enum.KeyCode. Use a Enum.KeyCode instead") -- ? We could also return Unknown keycode instead of this
		end
		return key
	end

	function input.keypress(key, isRepeatedKey)
		VirtualInputManager:SendKeyEvent(true, get_keycode(key), isRepeatedKey or false, nil)
	end

	function input.keyrelease(key, isRepeatedKey)
		VirtualInputManager:SendKeyEvent(false, get_keycode(key), isRepeatedKey or false, nil)
	end

	function input.keyclick(...)
		input.keypress(...)
		input.keyrelease(...)
	end
end

local Input = {
	KeyPress = input.keyclick,
	KeyDown = input.keypress,
	KeyUp = input.keyrelease,
}

do -- Mouse
	-- VirtualInputManager is typed to disallow a nil window, but it does not
	-- throw errors and tests rely on it `nil` being allowed
	local function mouse_generalized(mouseButton, isDown)
		return function(x, y, repeatCount)
			VirtualInputManager:SendMouseButtonEvent(
				x or UserInputService:GetMouseLocation().X,
				y or UserInputService:GetMouseLocation().Y,
				mouseButton,
				isDown,
				nil,
				repeatCount or 0
			)
		end
	end

	local mouse_map = { "LeftClick", "RightClick", "MiddleClick" }

	for i = 0, 2 do
		local lua_index = i + 1
		local base_name = "mouse" .. lua_index
		local press, release = mouse_generalized(i, true), mouse_generalized(i, false)

		local function click(...)
			press(...)
			release(...)
		end

		local up_name, down_name = base_name .. "press", base_name .. "release"
		input[up_name] = press
		input[down_name] = release
		input[base_name .. "click"] = click

		Input[mouse_map[lua_index]] = function(action)
			if 1 == action then
				press()
			elseif 2 == action then
				release()
			else
				click()
			end
		end

		alias[up_name] = { base_name .. "up" }
		alias[down_name] = { base_name .. "down" }
	end

	function input.mousemoveabs(x, y)
		local currentMousePosition = UserInputService:GetMouseLocation()
		local mouseX = x or currentMousePosition.X
		local mouseY = y or currentMousePosition.Y

		bridge:send("mousemove", {mouseX, mouseY})
	end

	function input.mousemoverel(x, y)
		input.mousemoveabs(
			x and UserInputService:GetMouseLocation().X + x,
			y and UserInputService:GetMouseLocation().Y + y
		)
	end

	Input.MoveMouse = input.mousemoverel
	Input.ScrollMouse = input.mousescroll

	function input.mousescroll(pixels, x, y)
		if type(pixels) == "boolean" then
			pixels = pixels and 120 or -120
		end

		local isForwardScroll = pixels >= 0 -- input.Position.Z is 1 when forward, -1 otherwise

		for i = 1, math.abs(pixels // 120) do
			VirtualInputManager:SendMouseWheelEvent(
				x or UserInputService:GetMouseLocation().X,
				y or UserInputService:GetMouseLocation().Y,
				isForwardScroll,
				nil
			)
			VirtualInputManager:WaitForInputEventsProcessed()
		end
	end
end

-- services
local http_service = game:GetService("HttpService")

-- variables
local script_env

-- functions
local httpContentTypeToHeader do
	-- * Keep this updated https://github.com/MaximumADHD/Roblox-Client-Tracker/blob/roblox/LuaPackages/Packages/_Index/HttpServiceMock/HttpServiceMock/httpContentTypeToHeader.lua
	-- * https://create.roblox.com/docs/reference/engine/enums/HttpContentType
	local httpContentTypeToHeaderLookup = {
		[Enum.HttpContentType.ApplicationJson] = "application/json",
		[Enum.HttpContentType.ApplicationUrlEncoded] = "application/x-www-form-urlencoded",
		[Enum.HttpContentType.ApplicationXml] = "application/xml",
		[Enum.HttpContentType.TextPlain] = "text/plain",
		[Enum.HttpContentType.TextXml] = "text/xml",
	}

	httpContentTypeToHeader = function(httpContentType: Enum.HttpContentType): string
		local value = httpContentTypeToHeaderLookup[httpContentType]
		assert(value, "Unable to map Enum.HttpContentType to Content-Type. Use a Content-Type string instead")
		return value
	end
end

-- main
local http_lib = {}

function http_lib.request(options)
	assert(type(options) == "table", "arg #1 must be type table")
	local Url = options.Url
	assert(type(Url) == "string", "Url must be type string")

	local HttpService = game:GetService("HttpService")

	-- * Hex decode (do we need this with bridged request?)
	-- Url = string.gsub(Url, "%%(%x%x)", function(hex)
	--     return string.char(tonumber(hex, 16))
	-- end)

	local Method = options.Method
	if Method then
		Method = string.upper(Method)
		if
			not (
				{ --https://github.com/MaximumADHD/Roblox-Client-Tracker/blob/04ab62513d220b3074c6433941864a705e0833f5/LuaPackages/Packages/_Index/RobloxRequests/RobloxRequests/src/session.lua#L160
					-- Others are: TRACE, CONNECT (need testing)
					GET = true,
					POST = true,
					HEAD = true,
					OPTIONS = true,
					PUT = true,
					DELETE = true,
					PATCH = true,
				}
			)[Method]
		then
			error("Invalid Method", 2)
		end
	else
		Method = "GET"
	end

	local Headers = options.Headers
	-- if Headers then -- ? Should it really be our problem if someone uses a different case on the header (e.g. all lowercase)
	-- local function normalizeHeaderName(header: string): string
	--     return string.lower(header)
	-- end
	-- local function normalizeHeaders(headers)
	--     local newHeaders = {}
	--     for name, value in headers do
	--         local lowercaseName = normalizeHeaderName(name)
	--         newHeaders[lowercaseName] = value
	--     end
	--     return newHeaders
	-- end
	-- else
	if not Headers then
		Headers = {}
	end

	local Body = options.Body
	if Method == "GET" or Method == "POST" then -- ! Important for Luarmor support
		-- Headers.Playercount = tostring(#game:GetService("Players"):GetPlayers())
		-- Headers.Requester = script_env.getexecutioncontext()
		local PlaceId = game.PlaceId
		local GameId = game.JobId -- ! Not sure, things that this could be are: (RbxAnalyticsService/game).GetPlaySessionId or RbxAnalyticsService.GetSessionId

		Headers["User-Agent"] = "Roblox/WinInet"

		Headers["Roblox-Place-Id"] = tostring(PlaceId)
		Headers["Roblox-Game-Id"] = GameId
		Headers["Roblox-Session-Id"] = HttpService:JSONEncode({
			-- Age = workspace.DistributedGameTime,
			-- BlockedPlayerIds = {},
			-- BrowserTrackerId = 0,
			-- ClientIpAddress = "1.1.1.1",
			-- CountryId = 0,
			GameId = GameId,
			-- GameJoinMetadata = { JoinSource = 0, RequestType = 0 },
			-- IsUserVoiceChatEnabled = game:GetService("VoiceChatService"):IsVoiceEnabledForUserIdAsync(game:GetService("Players").LocalPlayer.UserId),
			-- JoinType = "Specific",
			-- LanguageId = 0,
			-- Latitude = 0,
			-- Longitude = 0,
			-- MatchmakingDecisionId=null,
			PlaceId = PlaceId,
			-- PlatformTypeId = 0,
			-- PlaySessionFlags = 0,
			-- PlayerSignals = {},
			-- PolicyCountryId=null,
			-- RandomSeed2 = "",
			-- SessionId = "",
			-- SessionStarted = DateTime.fromUnixTimestamp(os.time() - workspace.DistributedGameTime):ToIsoDate(), --"1994-01-18T17: 11: 44.3095184Z",
			-- SourcePlaceId=null,
			-- SupportedLanguageId = 0,
			-- UserScoreObfuscated = 0,
			-- UserScorePublicKey = 0,
		})
	else
		Headers["User-Agent"] = table.concat({ script_env.identifyexecutor() }, "/")
	end
	if Method == "POST" or Method == "PATCH" then -- https://github.com/MaximumADHD/Roblox-Client-Tracker/blob/master/LuaPackages/Packages/_Index/roblox_http-request/http-request/RequestFunctions/Util/getHeaders.lua
		if not Headers["Content-Type"] then
			Headers["Content-Type"] = "application/json"
		end

		if Body and type(Body) == "table" then
			Body = HttpService:JSONEncode(Body)
		end
	end

	local HWID = script_env.gethwid() --game:GetService("RbxAnalyticsService"):GetClientId() -- TODO Find something better

	Headers["Incognito-Fingerprint"] = HWID
	Headers["Incognito-User-Identifier"] = HWID

	local params =
		{ -- https://github.com/MaximumADHD/Roblox-Client-Tracker/blob/master/LuaPackages/Packages/_Index/HttpRequest/HttpRequest/RequestFunctions/RequestInternal.lua#L6
			Url = Url,
			Method = Method, -- GET, POST, PATCH, PUT (DEFAULT: GET)

			Body = Body,
			Headers = Headers,
			Cookies = options.Cookies, -- Does this even work
		}
	local success, response = bridge:send("http_request", params)

	if not success then
		return error(`Failed to fetch URL '{Url}'`, 2)
	end

	return response
end

function http_lib.get(url, arg2, arg3) -- Must be compatible with params from HttpGet, HttpGetAsync, HttpService.GetAsync
	assert(type(url) == "string", `arg #1 must be type string`)
	assert(url ~= "", `arg #1 cannot be empty`)

	local args = {
		Method = "GET", -- Unneccessary, GET is DEFAULT
		Url = url,
	}

	local arg3_type = typeof(arg3)

	if arg3_type == "table" then -- HttpService.GetAsync
		args.Headers = arg3 --? In docs they are Variant though what other types does that imply ?
	elseif arg3_type == "EnumItem" and arg3.EnumType == Enum.HttpRequestType then -- HttpGet
		arg2 = arg3 -- because arg2 likely means 'synchronous' in this case and we don't need it
	end

	local arg2_type = typeof(arg2)

	if arg2_type == "boolean" then
		if arg2 then
			local Headers = args.Headers
			if not Headers then
				Headers = {}
				args.Headers = Headers
			end

			-- ! Roblox forces this anyway (regardless of this); So CachePolicy might be a good alternative if we figure out how it works
			Headers["Cache-Control"] = "no-cache" -- https://github.com/MaximumADHD/Roblox-Client-Tracker/blob/2719f6e1b2efba579994c0c5d762c6eed2cd5db0/LuaPackages/Packages/_Index/HttpServiceMock/HttpServiceMock/HttpServiceMock.lua#L97
		end
	end

	return http_lib.request(args).Body
end

function http_lib.post(url, data, arg3, arg4, arg5) -- Must be compatible with params from HttpPost, HttpPostAsync, HttpService.PostAsync
	assert(type(url) == "string", `arg #1 must be type string`)
	assert(url ~= "", `arg #1 cannot be empty`)

	local args = {
		Method = "POST",
		Url = url,
		Body = data,
	}

	if type(arg3) == "boolean" then -- HttpGet
		arg3, arg4, arg5 = arg4, arg5, nil -- because arg3 likely means 'synchronous' in this case and we don't need it
	end

	if arg5 then -- HttpService.PostAsync
		args.Headers = arg3 --? In docs they are Variant though what other types does that imply ?
	end

	if arg3 then
		local Headers = args.Headers
		if not Headers then
			Headers = {}
			args.Headers = Headers
		end

		Headers["Content-Type"] = if type(arg3) == "string" then arg3 else httpContentTypeToHeader(arg3) -- https://github.com/MaximumADHD/Roblox-Client-Tracker/blob/2719f6e1b2efba579994c0c5d762c6eed2cd5db0/LuaPackages/Packages/_Index/HttpServiceMock/HttpServiceMock/HttpServiceMock.lua#L151
	end

	local arg4_type = typeof(arg4)

	if arg4_type == "boolean" then -- HttpService.PostAsync
		if arg4 then -- compress
			local Headers = args.Headers
			if not Headers then
				Headers = {}
				args.Headers = Headers
			end

			Headers["Content-Encoding"] = "gzip" -- https://github.com/MaximumADHD/Roblox-Client-Tracker/blob/2719f6e1b2efba579994c0c5d762c6eed2cd5db0/LuaPackages/Packages/_Index/HttpServiceMock/HttpServiceMock/HttpServiceMock.lua#L147
		end
	end

	return http_lib.request(args).Body
end

local BLACKLISTED_EXTENSIONS = {
	".exe", ".bat",  ".com", ".cmd",  ".inf", ".ipa",
	".apk", ".apkm", ".osx", ".pif",  ".run", ".wsh",
	".bin", ".app",  ".vb",  ".vbs",  ".scr", ".fap",
	".cpl", ".inf1", ".ins", ".inx",  ".isu", ".job",
	".lnk", ".msi",  ".ps1", ".reg",  ".vbe", ".js",
	".x86", ".pif",  ".xlm", ".scpt", ".out", ".ba_",
	".jar", ".ahk",  ".xbe", ".0xe",  ".u3p", ".bms",
	".jse", ".cpl",  ".ex",  ".osx",  ".rar", ".zip",
	".7z",  ".py",   ".cpp", ".cs",   ".prx", ".tar",
	".",    ".wim",  ".htm", ".html", ".css",
	".appimage", ".applescript", ".x86_64", ".x64_64",
	".autorun", ".tmp", ".sys", ".dat", ".ini", ".pol",
	".vbscript", ".gadget", ".workflow", ".script",
	".action", ".command", ".arscript", ".psc1",
}
local FILESYSTEM_LOADED = false

local filesys_storage = {}
local script_env

-- functions
local function sanitize_path(dir_path: string)
	if #dir_path < 1 then
		return
	end

	dir_path = string.gsub(
		dir_path,
		"[\0\1\2\3\4\5\6\7\8\11\12\13\14\15\16\17\18\19\20\21\22\23\24\25\26\27\28\29\30\31]+[:*?\"<>|]+",
		""
	)
	return dir_path
end

local function sanitize_file_name(file_name: string): string?
	local _sanitized_name = sanitize_path(file_name) :: string
	if file_name ~= _sanitized_name then
		return error(`Blacklisted character in file name '{file_name}'`, 0)
	end

	local extention_splits = string.split(file_name, ".")
	local file_extension = extention_splits[#extention_splits]

	if table.find(BLACKLISTED_EXTENSIONS, `.{file_extension}`) then
		return error(`Blacklisted extension in file name '{file_name}'`, 0)
	end
	return file_name
end

local function parse_file_path(dir_path: string, no_sanity: boolean): { string }
	if not no_sanity then
		local _sanitized_path = sanitize_path(dir_path)
		if dir_path ~= _sanitized_path then
			return error(`Blacklisted character in path '{dir_path}'`, 0)
		end
	end

	local result = {}

	for path_name in string.gmatch(dir_path, "([^\\/]+)") do
		table.insert(result, path_name)
	end
	return result
end

local function get_dir_content(dir_data, path_list)
	local current_file = dir_data

	if type(current_file) == "table" and #path_list > 0 then
		for _, current_path in path_list do
			current_path = sanitize_file_name(current_path)

			local selected_file
			for path_name, path_content in current_file do
				if not (path_name == current_path or string.lower(path_name) == current_path) then continue end
				selected_file = path_content
			end

			if not selected_file then return end
			current_file = selected_file
		end
	end
	return current_file
end

local function get_dir_parent(dir_data, path_list)
	local folder_path = table.clone(path_list)
	table.remove(folder_path, #folder_path)

	-- checks folder existance
	local folder_dir = get_dir_content(dir_data, folder_path)
	if not (folder_dir and type(folder_dir) == "table") then
		return error(`Path '{table.concat(path_list, "/")}' parent {if not folder_dir then "doesn't exist" else "not a folder"}`, 0)
	end

	return folder_dir
end

local function fetch_paths_list(parent_path, dir_data, result)
	for file_name, value in dir_data do
		if not value then
			continue
		end
		local path_result = `{parent_path}/{file_name}`

		table.insert(result, path_result)
		if type(value) == "table" then
			fetch_paths_list(path_result, value, result)
		end
	end
end

local function get_all_file_paths(dir_data, path: string): { string }
	path = path or ""
	local result = {}

	fetch_paths_list(path, dir_data, result)
	return result
end

local function synchronize_to_external(path: string)
	local path_list = parse_file_path(path, true)
	local dir_parent = get_dir_parent(filesys_storage, path_list)
	local dir_name = sanitize_file_name(path_list[#path_list])

	local content_type = type(dir_parent[dir_name])
	local backslashed_path = string.gsub(path, "/", "\\")

	if content_type == "string" then
		bridge:send("write_file", backslashed_path, dir_parent[dir_name])
	elseif content_type == "table" then
		bridge:send("make_folder", backslashed_path)
	elseif content_type == "nil" then
		bridge:send("delete_dir", backslashed_path)
	end
end

-- main
local filesystem = {}

filesystem.readfile = function(dir_path: string): string?
	assert(type(dir_path) == "string", "arg #1 must be type string")

	local path_list = parse_file_path(dir_path)
	local file_content = get_dir_content(filesys_storage, path_list)

	local file_content_type = type(file_content)
	if file_content_type ~= "string" then
		return error(`Path '{dir_path}' {if file_content_type == "table" then "is a folder" else "cannot be determined"}`, 0)
	end

	return file_content
end

filesystem.writefile = function(dir_path: string, content: string)
	assert(type(dir_path) == "string", "arg #1 must be type string")
	assert(type(content) == "string", "arg #2 must be type string")

	local path_list = parse_file_path(dir_path)
	local file_parent = get_dir_parent(filesys_storage, path_list)

	local file_name = sanitize_file_name(path_list[#path_list])

	file_parent[file_name] = content
	task.spawn(synchronize_to_external, dir_path)
end

filesystem.appendfile = function(dir_path: string, content: string)
	assert(type(dir_path) == "string", "arg #1 must be type string")
	assert(type(content) == "string", "arg #2 must be type string")

	local path_list = parse_file_path(dir_path)
	local file_parent = get_dir_parent(filesys_storage, path_list)

	local file_name = sanitize_file_name(path_list[#path_list])

	file_parent[file_name] ..= content
	task.spawn(synchronize_to_external, dir_path)
end

filesystem.loadfile = function(dir_path: string): ()
	return script_env.loadstring(script_env.readfile(dir_path), dir_path)
end

filesystem.deletepath = function(dir_path: string)
	assert(type(dir_path) == "string", "arg #1 must be type string")

	local path_list = parse_file_path(dir_path)
	local file_parent = get_dir_parent(filesys_storage, path_list)

	local file_name = sanitize_file_name(path_list[#path_list])

	file_parent[file_name] = nil
	task.spawn(synchronize_to_external, dir_path)
end

filesystem.makefolder = function(dir_path: string)
	assert(type(dir_path) == "string", "arg #1 must be type string")

	local path_list = parse_file_path(dir_path)
	local dir_parent = get_dir_parent(filesys_storage, path_list)
	local dir_name = sanitize_file_name(path_list[#path_list])

	dir_parent[dir_name] = {}
	task.spawn(synchronize_to_external, dir_path)
end

filesystem.isfile = function(dir_path: string)
	assert(type(dir_path) == "string", "arg #1 must be type string")

	local path_list = parse_file_path(dir_path)
	local success, file_parent = pcall(get_dir_parent, filesys_storage, path_list)

	if success then
		local file_name = path_list[#path_list]

		return type(file_parent[file_name]) == "string"
	end
	return false
end

filesystem.isfolder = function(dir_path: string)
	assert(type(dir_path) == "string", "arg #1 must be type string")

	local path_list = parse_file_path(dir_path)
	local success, file_parent = pcall(get_dir_parent, filesys_storage, path_list)

	if success then
		local file_name = path_list[#path_list]

		return type(file_parent[file_name]) == "table"
	end
	return false
end

filesystem.listfiles = function(dir_path: string)
	assert(type(dir_path) == "string", "arg #1 must be type string")

	local path_list = parse_file_path(dir_path)
	local folder_dir = get_dir_content(filesys_storage, path_list)
	if type(folder_dir) ~= "table" then
		return error(`Path '{dir_path}' doesn't resolve to a folder`, 0)
	end

	return get_all_file_paths(folder_dir, dir_path)
end

filesystem.fs_loaded = function()
	return FILESYSTEM_LOADED
end

-- synchronizer
-- TODO: probably do external -> roblox file sync repeatedly
bridge:register_callback("synchronize_files", function()
	bridge:register_callback("synchronize_files", nil)
	local got_list, dir_list = bridge:send("list_files", "\\")

	if not got_list then
		return warn("Failed to load directory of workspace")
	end

	for _, path in dir_list do
		local success, path_type = bridge:send("get_path_type", path)
		if not success then
			continue
		end

		local path_list = parse_file_path(path, true)
		local path_parent = get_dir_parent(filesys_storage, path_list)
		local current_dir = path_list[#path_list]

		if path_type == "file" then
			local read_success, file_content = bridge:send("read_file", path)
			if not read_success then
				continue
			end

			path_parent[current_dir] = file_content
		elseif path_type == "folder" then
			path_parent[current_dir] = {}
		end
	end
	FILESYSTEM_LOADED = true
end)

local debug_lib = table.clone(debug)

debug_lib.getinfo = function(f, options)
	if type(options) == "string" then
		options = string.lower(options) -- if someone adds "L" for activelines and "l" for currentline then thats on them (it will just slow down this function because duplicate debug.infos)
	else
		options = "sflnu"
	end

	local result = {}

	for index = 1, #options do
		local option = string.sub(options, index, index)
		if "s" == option then
			local short_src = debug.info(f, "s")

			result.short_src = short_src
			result.source = "=" .. short_src
			result.what = if short_src == "[C]" then "C" else "Lua"
		elseif "f" == option then
			result.func = debug.info(f, "f")
		elseif "l" == option then
			result.currentline = debug.info(f, "l")
		elseif "n" == option then
			result.name = debug.info(f, "n")
		elseif "u" == option or option == "a" then
			local numparams, is_vararg = debug.info(f, "a")
			result.numparams = numparams
			result.is_vararg = if is_vararg then 1 else 0

			if "u" == option then
				result.nups = -1 --#debug.getupvalues(f)
			end
		end
	end

	return result
end

debug_lib.isvalidlevel = function(level)
	assert(type(level) == "number", "arg #1 must be type string")

	return select(1, pcall(getfenv, level))
end 

debug_lib.getmetatable = function(table_or_userdata)
	local result = getmetatable(table_or_userdata)

	if result == nil then -- No meta
		return
	end

	if type(result) == "table" and pcall(setmetatable, table_or_userdata, result) then -- This checks if it's real without overwriting
		return result --* We dont cache this as it will be the same always anyways
	end
	-- Metamethod bruteforcing
	-- For Full (except __gc & __tostring) Metamethod list Refer to - https://github.com/luau-lang/luau/blob/master/VM/src/ltm.cpp#L34

	-- Todo: Look into more ways of making metamethods error (like https://github.com/luau-lang/luau/blob/master/VM%2Fsrc%2Flvmutils.cpp#L174)

	--TODO We can also rebuild many non-dynamic things like len or arithmetic  metamethods since we know what arguments to expect in those usually

	local real_metamethods = {}

	xpcall(function()
		return table_or_userdata._
	end, function()
		real_metamethods.__index = debug.info(2, "f")
	end)

	xpcall(function()
		table_or_userdata._ = table_or_userdata
	end, function()
		real_metamethods.__newindex = debug.info(2, "f")
	end)

	-- xpcall(function()
	-- -- !MAKE __mode ERROR SOMEHOW..
	-- end, function()
	-- 	newTable.__mode = debug.info(2, "f")
	-- end)

	xpcall(function()
		return table_or_userdata:___() -- Make sure this doesn't exist in the table_or_userdata
	end, function()
		real_metamethods.__namecall = debug.info(2, "f")
	end)

	xpcall(function()
		table_or_userdata() -- ! This might not error on tables with __call defined
	end, function()
		real_metamethods.__call = debug.info(2, "f")
	end)

	xpcall(function() -- * LUAU
		for _ in table_or_userdata do -- ! This will never error on tables
		end
	end, function()
		real_metamethods.__iter = debug.info(2, "f")
	end)

	xpcall(function()
		return #table_or_userdata -- ! This will never error on tables, with userdata the issue is same as __concat - is it even a defined metamethod in that case?
	end, function()
		real_metamethods.__len = debug.info(2, "f")
	end)

	-- * Make sure type_check_semibypass lacks any metamethods
	local type_check_semibypass = {} -- bypass typechecks (which will return error instead of actual metamethod)

	xpcall(function()
		return table_or_userdata == type_check_semibypass -- ! This will never error (it calls __eq but we need it to error); ~= can also be used
	end, function()
		real_metamethods.__eq = debug.info(2, "f")
	end)

	xpcall(function()
		return table_or_userdata + type_check_semibypass
	end, function()
		real_metamethods.__add = debug.info(2, "f")
	end)

	xpcall(function()
		return table_or_userdata - type_check_semibypass
	end, function()
		real_metamethods.__sub = debug.info(2, "f")
	end)

	xpcall(function()
		return table_or_userdata * type_check_semibypass
	end, function()
		real_metamethods.__mul = debug.info(2, "f")
	end)

	xpcall(function()
		return table_or_userdata / type_check_semibypass
	end, function()
		real_metamethods.__div = debug.info(2, "f")
	end)

	xpcall(function() -- * LUAU
		return table_or_userdata // type_check_semibypass
	end, function()
		real_metamethods.__idiv = debug.info(2, "f")
	end)

	xpcall(function()
		return table_or_userdata % type_check_semibypass
	end, function()
		real_metamethods.__mod = debug.info(2, "f")
	end)

	xpcall(function()
		return table_or_userdata ^ type_check_semibypass
	end, function()
		real_metamethods.__pow = debug.info(2, "f")
	end)

	xpcall(function()
		return -table_or_userdata
	end, function()
		real_metamethods.__unm = debug.info(2, "f")
	end)

	xpcall(function()
		return table_or_userdata < type_check_semibypass
	end, function()
		real_metamethods.__lt = debug.info(2, "f")
	end)

	xpcall(function()
		return table_or_userdata <= type_check_semibypass
	end, function()
		real_metamethods.__le = debug.info(2, "f")
	end)

	xpcall(function()
		return table_or_userdata .. type_check_semibypass -- TODO Not sure if this would work on userdata.. (do they even have __concat defined? would it be called?)
	end, function()
		real_metamethods.__concat = debug.info(2, "f")
	end)

	-- xpcall(function()
	-- -- !MAKE __type ERROR SOMEHOW..
	-- end, function()
	-- 	newTable.__type = debug.info(2, "f")
	-- end)
	-- FAKE __type INBOUND
	real_metamethods.__type = typeof(table_or_userdata)

	real_metamethods.__metatable = getmetatable(game) -- "The metatable is locked"

	-- xpcall(function()
	-- -- !MAKE __tostring  ERROR SOMEHOW..
	-- end, function()
	-- 	newTable.__tostring = debug.info(2, "f")
	-- end)

	-- FAKE __tostring INBOUND (We wrap it because 1. No rawtostring & 2. In case Table_or_Userdata Name changes)
	real_metamethods.__tostring = function()
		return tostring(table_or_userdata)
	end

	-- xpcall(function()
	-- -- !MAKE __gc ERROR SOMEHOW..
	-- end, function()
	-- 	newTable.__gc = debug.info(2, "f")
	-- end)

	-- table.freeze(real_metamethods) -- Not using for compatibility -- We can't check readonly state of an actual metatable sadly (or can we?)
	return real_metamethods
end

debug_lib.setmetatable = function(table_or_userdata, metatable)
	assert(type(table_or_userdata) == "table" or type(table_or_userdata) == "userdata", "First argument must be a table or userdata")
	assert(type(metatable) == "table" or metatable == nil, "Second argument must be a table or nil")

	local success, result = pcall(setmetatable, table_or_userdata, metatable)
	if not success then
		error("Failed to set metatable: " .. result)
	end

	return table_or_userdata
end

local crypt = {}

do
	local b64 = {
		encode = function(input)
			local Type = type(input)
			if Type ~= "string" and Type ~= "number" then
				return error("arg #1 must be type string or number", 2)
			end

			return if input == "" then input else buffer.tostring(base64.encode(buffer.fromstring(input)))
		end,
		decode = function(input)
			local Type = type(input)
			if Type ~= "string" and Type ~= "number" then
				return error("arg #1 must be type string or number", 2)
			end

			return if input == "" then input else buffer.tostring(base64.decode(buffer.fromstring(input)))
		end,
	}
	crypt.base64 = b64

	crypt.base64encode = b64.encode
	crypt.base64_encode = b64.encode

	crypt.base64decode = b64.decode
	crypt.base64_decode = b64.decode
end

do
	local modes = {}

	for _, ciphermode in { "ECB", "CBC", "PCBC", "CFB", "OFB", "CTR" } do -- Missing: GCM (important)
		local encrypt = aes["encrypt_" .. ciphermode]
		local decrypt = aes["decrypt_" .. ciphermode]

		modes[string.lower(ciphermode)] = { encrypt = encrypt, decrypt = decrypt or encrypt }
	end

	-- Function to add PKCS#7 padding to a string
	local function PKCS7_unpad(inputString)
		local blockSize = 16
		local length = (#inputString % blockSize)

		-- Only add padding if needed
		if 0 == length then
			return inputString
		end

		local paddingSize = blockSize - length

		local padding = string.rep(string.char(paddingSize), paddingSize)
		return inputString .. padding
	end

	-- Function to remove PKCS#7 padding from a padded string
	local function PKCS7_pad(paddedString)
		local lastByte = string.byte(paddedString, -1)

		-- Check if padding is present
		if lastByte <= 16 and 0 < lastByte then
			return string.sub(paddedString, 1, -lastByte - 1)
		else
			return paddedString
		end
	end

	local function table_type(t)
		local ct = 1
		for i in t do
			if i ~= ct then
				return "dictionary"
			end
			ct += 1
		end
		return "array"
	end

	local function bytes_to_char(t)
		return string.char(unpack(t))
	end

	local function crypt_generalized(action: string?)
		return function(data: string, key: string, iv: string?, mode: string?): (string, string)
			if mode and type(mode) == "string" then
				mode = string.lower(mode)
				mode = modes[mode]
			else
				mode = modes.cbc -- Default
			end

			if iv then
				iv = crypt.base64decode(iv)
				pcall(function()
					iv = game:GetService("HttpService"):JSONDecode(iv)
				end)
				if 16 < #iv then
					iv = string.sub(iv, 1, 16)
				elseif #iv < 16 then
					iv = PKCS7_unpad(iv)
				end
			end

			pcall(function()
				key = crypt.base64decode(key)
			end)

			-- TODO This code below is even worse
			local crypt_f = mode[action]
			data, iv = crypt_f(key, if action == "encrypt" then PKCS7_unpad(data) else crypt.base64decode(data), iv)

			data = bytes_to_char(data)

			if action == "decrypt" then
				data = PKCS7_pad(data)
			else
				if table_type(iv) == "array" then
					iv = bytes_to_char(iv)
				else
					iv = game:GetService("HttpService"):JSONEncode(iv)
				end
				iv = crypt.base64encode(iv)
				data = crypt.base64encode(data)
			end

			return data, iv
		end
	end

	crypt.encrypt = crypt_generalized("encrypt")
	crypt.decrypt = crypt_generalized("decrypt")

	-- * Tests
	-- for mode in { "ECB", "CBC", "PCBC", "CFB", "OFB", "CTR" } do
	--     local key = "10syfhOVeMW[F#Ojbqjv[)R7,Ad=diNB"
	--     local data = "test lorem ips\1" -- "xtest lorem ips\1" breaks our padding algorithm sadly lol
	--     local encrypted, iv = crypt.encrypt(data, key, nil, mode)

	--     assert(iv, "crypt.encrypt should return an IV")
	--     local decrypted = crypt.decrypt(encrypted, key, iv, mode)

	--     assert(decrypted == data, "Failed to decrypt raw string from encrypted data")
	-- end
end

function crypt.generatebytes(size: number): string
	local randomBytes = table.create(size)
	for i = 1, size do
		randomBytes[i] = string.char(math.random(0, 255))
	end

	return crypt.base64encode(table.concat(randomBytes))
end

function crypt.generatekey()
	return crypt.generatebytes(32)
end

function crypt.hash(data: string, algorithm: string): string
	return hashlib[string.gsub(algorithm, "-", "_")](data)
end

function crypt.hmac(data: string, key: string, asBinary: boolean): string
	--* sha512_256 because synapse uses it - https://web.archive.org/web/20231030192906/https://synllc.github.io/synapse-x-documentation/reference/namespace/syn.crypt.html#hmac - https://libsodium.gitbook.io/doc/secret-key_cryptography/secret-key_authentication#algorithm-details

	return hashlib.hmac(hashlib.sha512_256, data, key, asBinary)
end

local script_env

-- main
local closure = {}

function closure.iscclosure(func)
	assert(type(func) == "function", `arg #1 must be type function`)
	return debug.info(func, "s") == "[C]"
end

function closure.islclosure(func)
	assert(type(func) == "function", `arg #1 must be type function`)
	return debug.info(func, "s") ~= "[C]"
end

function closure.getcallingscript(stackCount: number)
	stackCount = stackCount or 3

	for stackLvl = stackCount, 0, -1 do
		local func = debug.info(stackLvl, "f")
		stackLvl -= 1
		if not func then
			continue
		end

		local script = rawget(getfenv(func), "script")

		if typeof(script) == "Instance" and script:IsA("BaseScript") then
			return script
		end
	end
end

local function newWrappedCClosure(func)
	if script_env.iscclosure(func) then
		return func
	end

	return coroutine.wrap(function(...)
		local args = { ... }

		while true do
			args = { coroutine.yield(func(unpack(args))) }
		end
	end)
end

function closure.newcclosure(func)
	assert(type(func) == "function", `arg #1 must be type function`)
	return newWrappedCClosure(func)
end

function closure.newlclosure(func)
	return function(...)
		return func(...)
	end
end

function closure.isexecutorclosure(func)
	if script_env.iscclosure(func) then
		return debug.info(func, "n") == "" -- * Hopefully there aren't any false positives
	end
	local f_env = getfenv(func)
	return f_env.script.Parent == nil or f_env == getfenv(0) -- TODO The second part can be fooled if isexecutorclosure(HijackedModule.Function)
end

function closure.checkcaller()
	return 3 <= script_env.getthreadidentity()
end

function closure.clonefunction(func)
	return if script_env.iscclosure(func) then script_env.newcclosure(func) else script_env.newlclosure(func)
end

function closure.securecall(func, scriptOrEnv, ...): ...any
	assert(type(func) == "function", `arg #1 must be type function`)

	local type_scriptOrEnv = typeof(scriptOrEnv)
	local virtual_env
	do
		if type_scriptOrEnv == "Instance" and scriptOrEnv:IsA("LuaScriptContainer") then
			virtual_env = setmetatable({}, { __index = script_env.getrenv() })
			virtual_env.script = scriptOrEnv
		elseif type_scriptOrEnv == "table" then
			virtual_env = scriptOrEnv
		else
			return error(`invalid argument #2 (LuaSourceContainer | table expected, got {type_scriptOrEnv})`, 2)
		end
	end

	return coroutine.wrap(function(...)
		setfenv(0, virtual_env)
		setfenv(1, virtual_env)

		return func(...)
	end)(...)
end

local cache = {}
local script_env

local CloneRefs = { Clones = setmetatable({}, { __mode = "ks" }), Originals = setmetatable({}, { __mode = "vs" }) }

local function ReturnOriginal(instance)
	local CloneInfo = CloneRefs.Clones[instance]
	if CloneInfo then
		return CloneInfo.Original
	end
end

function cache.cloneref(instance)
	local Original = ReturnOriginal(instance)
	if Original then
		instance = Original
	end

	local Clone = newproxy(true)
	local Mt_Clone = getmetatable(Clone)
	local Mt_Real = script_env.getrawmetatable(instance)

	local CloneInfo = CloneRefs.Originals[instance]
	if not CloneInfo then
		CloneInfo = { Original = instance, __type = Mt_Real.__type }
		CloneRefs.Originals[instance] = CloneInfo
	end

	CloneRefs.Clones[Clone] = CloneInfo

	for Metamethod, Value in Mt_Real do
		Mt_Clone[Metamethod] = type(Value) == "function"
			and function(self, ...)
				return Value(instance, ...)
			end
			or Value
	end

	return Clone
end

function cache.compareinstances(instance, instance2)
	local CloneInfo = CloneRefs.Clones[instance]
	local CloneInfo2 = CloneRefs.Clones[instance2]
	if CloneInfo then
		instance = CloneInfo.Original
	end
	if CloneInfo2 then
		instance2 = CloneInfo2.Original
	end

	return instance == instance2
end

local bit_lib = table.clone(bit32)

function bit_lib.badd(num_first, num_second)
	return num_first + num_second
end

function bit_lib.bsub(num_first, num_second)
	return num_first - num_second
end

function bit_lib.bdiv(num_first, num_second)
	return num_first / num_second
end

function bit_lib.bmul(num_first, num_second)
	return num_first * num_second
end

function bit_lib.tobit(num)
	num %= bit32.bxor(num, 32)
	if 0x80000000 < num then
		num -= bit32.bxor(num, 32)
	end
	return num
end

function bit_lib.tohex(num, hex)
	if not hex then
		hex = 8
	end
	local up

	if hex <= 0 then
		if hex == 0 then
			return ""
		end
		up = true
		hex = -hex
	end

	num %= (2 ^ 32)
	num = bit32.band(num, 16 ^ hex - 1)
	return string.format("%0" .. hex .. (up and "X" or "a"), num)
end

function bit_lib.rol(number, rotateBy)
	return bit_lib.tobit(bit32.lrotate(bit32.bxor(number % 2, 32), rotateBy % 32))
end

function bit_lib.ror(number, rotateBy)
	return bit_lib.tobit(bit32.rrotate(bit32.bxor(number % 2, 32), rotateBy % 32))
end

function bit_lib.bpopcount(value)
	local count = 0
	while 0 < value do
		if value % 2 == 1 then
			count += 1
		end
		value //= 2
	end
	return count
end

bit_lib.bswap = bit32.byteswap

closure.getthread = coroutine.running

crypt.lz4 = lz4
crypt.lz4compress = lz4.compress
crypt.lz4decompress = lz4.decompress

input.Input = Input

rconsole.consoleclear = rconsole.rconsoleclear
rconsole.consolecreate = rconsole.rconsolecreate
rconsole.consoledestroy = rconsole.rconsoledestroy
rconsole.consoleinput = rconsole.rconsoleinput
rconsole.consoleprint = rconsole.rconsoleprint
rconsole.consolename = rconsole.rconsolename

rconsole.consolesettitle = rconsole.rconsolesettitle
rconsole.rconsolename = rconsole.rconsolesettitle

ENV = getrenv() or getgenv()
THREADS = {
	setthreadcontext = setthreadidentity,
	setidentity = setthreadidentity,
	setthreadidentity = setthreadidentity,
	getthreadidentity = getthreadidentity,
	getidentity = getthreadidentity,
	getthreadcontext = getthreadidentity,
	printidentity = function()
		print("Current identity "..thread.thread_identity)
	end
}

currentLIBS = {
	instance_lib,
	scripts,
	THREADS,
	rconsole,
	misc,
	input,
	http_lib,
	filesystem,
	debug_lib,
	closure,
	cache,
	bit_lib
}

ENV.Decomplie = disassemble

for lib = 1, #currentLIBS do
	local libs = currentLIBS[lib]
	for index, value in libs do
		ENV[index] = value
	end
end

return ENV
