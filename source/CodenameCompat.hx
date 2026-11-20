package;

#if sys
import sys.FileSystem;
import sys.io.File;
#end
import haxe.Json;
import flixel.util.FlxColor;

using StringTools;

/**
 * CodenameCompat (Shagustus) - loads Codename Engine mods inside PE Extra.
 *
 * Handles:
 *   - charts      songs/<song>/charts/<diff>.json + meta.json      -> SwagSong
 *   - audio       songs/<song>/song/Inst.ogg / Voices.ogg          -> found by Paths.inst/voices
 *   - characters  data/characters/<name>.xml                       -> CharacterFile
 *   - stages      data/stages/<name>.xml                           -> StageFile + generated stages/<name>.lua
 *   - freeplay    auto-generates hidden-story weeks (weeks/cnauto-*.json) so the songs show up
 *   - events      Camera Movement, BPM Change, Add Camera Zoom, Play Animation, Scroll Speed Change
 *                 (anything else is passed through by name so Lua scripts can catch it in onEvent)
 *
 * NOT handled: Codename HScript (.hx song/stage/character scripts), split per-character vocals,
 * more than 2 visible strumlines (extra lines are folded onto the opponent side as GF Sing notes).
 * Per-strumline key counts are kept (PE Extra supports different player/opponent keys).
 */
class CodenameCompat
{
	public static inline var DEFAULT_KEYS:Int = 4;

	// ------------------------------------------------------------------ helpers

	static function exists(path:String):Bool
	{
		#if sys
		return path != null && FileSystem.exists(path);
		#else
		return false;
		#end
	}

	static function read(path:String):String
	{
		#if sys
		return File.getContent(path);
		#else
		return null;
		#end
	}

	/** Full path of a file in the active mod folders (or preload assets), or null. */
	public static function findModFile(key:String):String
	{
		#if MODS_ALLOWED
		var p:String = Paths.modFolders(key);
		if (exists(p)) return p;
		#end
		var a:String = Paths.getPreloadPath(key);
		if (exists(a)) return a;
		return null;
	}

	static function num(v:Dynamic, def:Float):Float
	{
		if (v == null) return def;
		var f:Float = Std.parseFloat(Std.string(v));
		return Math.isNaN(f) ? def : f;
	}

	static function str(v:Dynamic, def:String):String
	{
		if (v == null) return def;
		var s:String = Std.string(v);
		return s.length > 0 ? s : def;
	}

	static function attr(x:Xml, name:String, def:String):String
	{
		var v:String = x.get(name);
		return v != null ? v : def;
	}

	static function bool(x:Xml, name:String, def:Bool):Bool
	{
		var v:String = x.get(name);
		if (v == null) return def;
		return v.toLowerCase().trim() == 'true';
	}

	static function colorArray(c:String, def:Array<Int>):Array<Int>
	{
		if (c == null) return def;
		var parsed:Null<FlxColor> = FlxColor.fromString(c.trim());
		if (parsed == null) return def;
		var col:FlxColor = parsed;
		return [col.red, col.green, col.blue];
	}

	static function parseIndices(s:String):Array<Int>
	{
		var out:Array<Int> = [];
		if (s == null || s.trim() == '') return out;
		for (rawPart in s.split(','))
		{
			var part:String = rawPart.trim();
			if (part.indexOf('..') >= 0)
			{
				var r = part.split('..');
				var a:Null<Int> = Std.parseInt(r[0]);
				var b:Null<Int> = Std.parseInt(r[1]);
				if (a == null || b == null) continue;
				if (a <= b) { for (i in a...b + 1) out.push(i); }
				else { var i:Int = a; while (i >= b) { out.push(i); i--; } }
			}
			else
			{
				var v:Null<Int> = Std.parseInt(part);
				if (v != null) out.push(v);
			}
		}
		return out;
	}

	static function readJson(path:String):Dynamic
	{
		if (path == null) return null;
		try { return Json.parse(read(path)); }
		catch (e:Dynamic) { trace('CodenameCompat: bad JSON in $path: $e'); return null; }
	}

	// ------------------------------------------------------------------ song folders

	static var folderCache:Map<String, String> = new Map();

	/**
	 * Codename song folders keep their real names ("Last Chance"), Psych formats them
	 * ("last-chance"). Returns the real folder name for a song, or the formatted one.
	 */
	public static function realSongFolder(song:String):String
	{
		var formatted:String = Paths.formatToSongPath(song);
		#if MODS_ALLOWED
		var roots:Array<String> = [];
		if (Paths.currentModDirectory != null && Paths.currentModDirectory.length > 0)
			roots.push(Paths.mods(Paths.currentModDirectory + '/songs/'));
		for (mod in Paths.getGlobalMods()) roots.push(Paths.mods(mod + '/songs/'));
		roots.push(Paths.mods('songs/'));

		for (root in roots)
		{
			var cacheKey = root + '|' + formatted;
			if (folderCache.exists(cacheKey)) return folderCache.get(cacheKey);
			if (!exists(root) || !FileSystem.isDirectory(root)) continue;
			if (exists(root + formatted)) { folderCache.set(cacheKey, formatted); return formatted; }
			for (dir in FileSystem.readDirectory(root))
			{
				if (Paths.formatToSongPath(dir) == formatted && FileSystem.isDirectory(root + dir))
				{
					folderCache.set(cacheKey, dir);
					return dir;
				}
			}
		}
		#end
		return formatted;
	}

	// ------------------------------------------------------------------ audio

	/** True if songs/<folder>/song/<file>.ogg (Codename layout) or songs/<folder>/<file>.ogg exists in the mods. */
	static function songAudioExists(folder:String, file:String):Bool
	{
		#if MODS_ALLOWED
		var real = realSongFolder(folder);
		if (exists(Paths.modsSounds('songs/' + real + '/song', file))) return true;
		if (exists(Paths.modsSounds('songs/' + real, file))) return true;
		#end
		return false;
	}

	// ------------------------------------------------------------------ charts

	static function difficultyFrom(folder:String, jsonInput:String):String
	{
		if (jsonInput == folder) return 'normal';
		if (jsonInput.startsWith(folder + '-')) return jsonInput.substr(folder.length + 1);
		return 'normal';
	}

	/**
	 * Called from Song.loadFromJson. Returns a SwagSong-shaped object, or null if
	 * this isn't a Codename song.
	 */
	public static function loadSong(folder:String, jsonInput:String):Dynamic
	{
		if (jsonInput == 'events') return null;
		var diff:String = difficultyFrom(folder, jsonInput);
		var base:String = 'songs/' + realSongFolder(folder) + '/';

		var chartPath:String = findModFile(base + 'charts/' + diff + '.json');
		if (chartPath == null) chartPath = findModFile(base + 'charts/' + diff.toLowerCase() + '.json');
		if (chartPath == null) return null;

		var chart:Dynamic = readJson(chartPath);
		if (chart == null || chart.strumLines == null) return null;

		var meta:Dynamic = readJson(findModFile(base + 'meta-' + diff + '.json'));
		if (meta == null) meta = readJson(findModFile(base + 'meta.json'));
		if (meta == null) meta = chart.meta;
		if (meta == null) meta = {};

		try { return convertChart(chart, meta, folder); }
		catch (e:Dynamic) { trace('CodenameCompat: failed to convert $chartPath: $e'); return null; }
	}

	public static function convertChart(chart:Dynamic, meta:Dynamic, folder:String):Dynamic
	{
		var bpm:Float = num(meta.bpm, 100);
		if (bpm <= 0) bpm = 100;
		var beats:Int = Math.round(num(meta.beatsPerMeasure, 4));
		if (beats <= 0) beats = 4;
		var songSpeed:Float = num(chart.scrollSpeed, 1);

		var strumLines:Array<Dynamic> = chart.strumLines != null ? chart.strumLines : [];
		var noteTypes:Array<Dynamic> = chart.noteTypes != null ? chart.noteTypes : [];

		// --- characters + key counts (PE Extra supports different player/opponent key counts)
		var player1:String = 'bf', player2:String = 'dad', gfVersion:String = 'gf';
		var playerKeys:Int = -1, oppKeys:Int = -1;
		var foundG = false;

		// multikey mods often set the real key count with a "Set Key Count" event
		var eventKeys:Int = -1;
		if (chart.events != null)
			for (e in (chart.events : Array<Dynamic>))
				if (Std.string(e.name) == 'Set Key Count' && e.params != null && num(e.time, 0) <= 1)
					eventKeys = Std.int(num(e.params[0], -1));

		var lineKeys:Array<Int> = [];
		for (sl in strumLines) lineKeys.push(effectiveKeys(sl, eventKeys));

		for (i in 0...strumLines.length)
		{
			var sl:Dynamic = strumLines[i];
			var t:Int = Std.int(num(sl.type, 0));
			var chars:Array<Dynamic> = sl.characters != null ? sl.characters : [];
			var first:String = chars.length > 0 ? Std.string(chars[0]) : null;
			var k:Int = ManiaConverter.clampKeys(lineKeys[i]);
			if (t == 1 && playerKeys < 0) { playerKeys = k; if (first != null) player1 = first; }
			else if (t == 0 && oppKeys < 0) { oppKeys = k; if (first != null) player2 = first; }
			else if (t == 2 && !foundG && first != null) { gfVersion = first; foundG = true; }
		}
		if (playerKeys < 0) playerKeys = DEFAULT_KEYS;
		if (oppKeys < 0) oppKeys = DEFAULT_KEYS;

		// --- events, pass 1: BPM + camera
		var events:Array<Dynamic> = chart.events != null ? (chart.events : Array<Dynamic>).copy() : [];
		events.sort(function(a, b) return Reflect.compare(num(a.time, 0), num(b.time, 0)));

		var bpmChanges:Array<{time:Float, bpm:Float}> = [];
		var camEvents:Array<{time:Float, line:Int}> = [];
		for (e in events)
		{
			var params:Array<Dynamic> = e.params != null ? e.params : [];
			switch (Std.string(e.name))
			{
				case 'BPM Change':
					bpmChanges.push({time: num(e.time, 0), bpm: num(params[0], bpm)});
				case 'Camera Movement':
					camEvents.push({time: num(e.time, 0), line: Std.int(num(params[0], 0))});
				default:
			}
		}

		function bpmAt(time:Float):Float
		{
			var b = bpm;
			for (c in bpmChanges) { if (c.time <= time) { b = c.bpm; } else { break; } }
			return b > 0 ? b : bpm;
		}

		// --- events, pass 2: everything else -> Psych-style events
		var psychEvents:Array<Array<Dynamic>> = [];
		for (e in events)
		{
			var name:String = Std.string(e.name);
			if (name == 'BPM Change' || name == 'Camera Movement') continue;
			var params:Array<Dynamic> = e.params != null ? e.params : [];
			var time:Float = num(e.time, 0);
			var pe:Array<Dynamic> = convertEvent(name, params, strumLines, songSpeed, bpmAt(time));
			if (pe != null) psychEvents.push([time, [pe]]);
		}

		// --- notes (player lines -> player side, opponent + extra lines -> opponent side)
		var allNotes:Array<{time:Float, sus:Float, player:Bool, lane:Int, type:String}> = [];
		for (li in 0...strumLines.length)
		{
			var sl:Dynamic = strumLines[li];
			var t:Int = Std.int(num(sl.type, 0));
			var slKeys:Int = lineKeys[li];
			var isPlayer = t == 1;
			var sideKeys = isPlayer ? playerKeys : oppKeys;
			var notes:Array<Dynamic> = sl.notes != null ? sl.notes : [];
			for (n in notes)
			{
				var id:Int = Std.int(num(n.id, 0));
				if (id < 0) continue;
				var lane:Int = ManiaConverter.mapLane(id % slKeys, slKeys, sideKeys);
				var typeIdx:Int = Std.int(num(n.type, 0));
				var type:String = (typeIdx > 0 && typeIdx - 1 < noteTypes.length) ? mapNoteType(Std.string(noteTypes[typeIdx - 1])) : '';
				if (t == 2 && type == '') type = 'GF Sing';
				allNotes.push({time: num(n.time, 0), sus: Math.max(0, num(n.sLen, 0)), player: isPlayer, lane: lane, type: type});
			}
		}
		allNotes.sort(function(a, b) return Reflect.compare(a.time, b.time));

		// --- sections (BPM/camera changes snap to section starts)
		var lastTime:Float = 0;
		for (n in allNotes) lastTime = Math.max(lastTime, n.time + n.sus);
		for (pe in psychEvents) lastTime = Math.max(lastTime, pe[0]);

		var sections:Array<Dynamic> = [];
		var curBpm:Float = bpm;
		var t:Float = 0;
		var bi = 0, ci = 0, ni = 0;
		var curLine:Int = -1;
		while (t <= lastTime || sections.length == 0)
		{
			var changed = false;
			while (bi < bpmChanges.length && bpmChanges[bi].time <= t + 1)
			{
				var nb = bpmChanges[bi].bpm;
				if (nb > 0 && nb != curBpm) { curBpm = nb; changed = true; }
				bi++;
			}
			var len:Float = beats * 60000 / curBpm;

			while (ci < camEvents.length && camEvents[ci].time <= t + len * 0.25)
			{
				curLine = camEvents[ci].line;
				ci++;
			}
			var lineType:Int = (curLine >= 0 && curLine < strumLines.length) ? Std.int(num(strumLines[curLine].type, 0)) : 0;
			var mustHit:Bool = lineType == 1;
			var leftKeys:Int = mustHit ? playerKeys : oppKeys;

			var end:Float = t + len;
			var secNotes:Array<Array<Dynamic>> = [];
			while (ni < allNotes.length && allNotes[ni].time < end)
			{
				var n = allNotes[ni++];
				var data:Int = (n.player == mustHit) ? n.lane : leftKeys + n.lane;
				secNotes.push([n.time, data, n.sus, n.type, [0]]);
			}

			sections.push({
				sectionNotes: secNotes,
				lengthInSteps: beats * 4,
				mustHitSection: mustHit,
				gfSection: lineType == 2,
				bpm: curBpm,
				changeBPM: changed,
				timeSignature: [beats, 4],
				changeSignature: false,
				altAnim: false,
				changeKeys: false,
				playerKeys: playerKeys,
				opponentKeys: oppKeys
			});
			t = end;
		}

		// --- song name must format to the folder name or the audio won't be found
		var name:String = str(meta.displayName, str(meta.name, folder));
		if (Paths.formatToSongPath(name) != Paths.formatToSongPath(folder)) name = folder;

		var needsVoices:Bool = meta.needsVoices != false;
		if (needsVoices && !songAudioExists(folder, 'Voices')) needsVoices = false; // only split vocals, or none

		return {
			song: name,
			notes: sections,
			events: psychEvents,
			bpm: bpm,
			timeSignature: [beats, 4],
			needsVoices: needsVoices,
			speed: songSpeed,
			playerKeyAmount: playerKeys,
			opponentKeyAmount: oppKeys,
			player1: player1,
			player2: player2,
			gfVersion: gfVersion,
			stage: str(chart.stage, 'stage'),
			arrowSkin: '',
			splashSkin: '',
			skinModifier: '',
			validScore: true
		};
	}

	/** Key count of a strumline: keyCount, a Set Key Count event, or the highest note id + 1 — whichever is largest. */
	static function effectiveKeys(sl:Dynamic, eventKeys:Int):Int
	{
		var k:Int = Std.int(num(sl.keyCount, DEFAULT_KEYS));
		if (eventKeys > k) k = eventKeys;
		var notes:Array<Dynamic> = sl.notes != null ? sl.notes : [];
		for (n in notes)
		{
			var id:Int = Std.int(num(n.id, 0));
			if (id + 1 > k) k = id + 1;
		}
		return k < 1 ? DEFAULT_KEYS : k;
	}

	static function charTarget(strumLines:Array<Dynamic>, line:Int):String
	{
		if (line < 0 || line >= strumLines.length) return 'dad';
		return switch (Std.int(num(strumLines[line].type, 0))) {
			case 1: 'bf';
			case 2: 'gf';
			default: 'dad';
		}
	}

	static function convertEvent(name:String, params:Array<Dynamic>, strumLines:Array<Dynamic>, songSpeed:Float, bpm:Float):Array<Dynamic>
	{
		function p(i:Int):String return (i < params.length && params[i] != null) ? Std.string(params[i]) : '';

		switch (name)
		{
			case 'Add Camera Zoom':
				// Codename: [amount, camera]
				var cam = p(1).toLowerCase();
				return cam.indexOf('hud') >= 0 ? ['Add Camera Zoom', '0', p(0)] : ['Add Camera Zoom', p(0), '0'];

			case 'Play Animation':
				// Codename: [strumLine, anim, force]
				return ['Play Animation', p(1), charTarget(strumLines, Std.int(num(params[0], 0)))];

			case 'Scroll Speed Change':
				// Codename: [tween, speed, durationInSteps, ease, easeType]
				var speed:Float = num(params[1], songSpeed);
				var tween:Bool = Std.string(params[0]) == 'true';
				var secs:Float = tween ? num(params[2], 4) * (15 / bpm) : 0;
				var mult:Float = songSpeed > 0 ? speed / songSpeed : 1;
				return ['Change Scroll Speed', Std.string(mult), Std.string(secs)];

			default:
				var rest:Array<String> = [for (i in 1...params.length) Std.string(params[i])];
				return [name, p(0), rest.join(', ')];
		}
	}

	static function mapNoteType(t:String):String
	{
		if (t == null) return '';
		return switch (t.toLowerCase().trim()) {
			case '' | 'default' | 'default note': '';
			case 'hurt note' | 'hurt': 'Hurt Note';
			case 'no anim note' | 'no animation' | 'no anim': 'No Animation';
			case 'alt anim note' | 'alt animation' | 'alt anim': 'Alt Animation';
			case 'gf sing' | 'gf note' | 'girlfriend sing': 'GF Sing';
			case 'hey!' | 'hey note': 'Hey!';
			default: t;
		}
	}

	// ------------------------------------------------------------------ characters

	/** Converts data/characters/<name>.xml to a Psych CharacterFile, or null. */
	public static function characterFromXml(name:String):Dynamic
	{
		var path:String = findModFile('data/characters/' + name + '.xml');
		if (path == null) return null;
		try
		{
			var root:Xml = Xml.parse(read(path)).firstElement();
			var anims:Array<Dynamic> = [];
			for (node in root.elementsNamed('anim'))
			{
				anims.push({
					anim: attr(node, 'name', ''),
					name: attr(node, 'anim', ''),
					fps: Std.int(num(node.get('fps'), 24)),
					loop: bool(node, 'loop', false),
					indices: parseIndices(node.get('indices')),
					offsets: [num(node.get('x'), 0), num(node.get('y'), 0)]
				});
			}
			return {
				animations: anims,
				image: 'characters/' + attr(root, 'sprite', name),
				scale: num(root.get('scale'), 1),
				sing_duration: num(root.get('holdTime'), 4),
				healthicon: attr(root, 'icon', name),
				position: [num(root.get('x'), 0), num(root.get('y'), 0)],
				camera_position: [num(root.get('camx'), 0), num(root.get('camy'), 0)],
				flip_x: bool(root, 'flipX', false),
				no_antialiasing: !bool(root, 'antialiasing', true),
				healthbar_colors: colorArray(root.get('color'), [161, 161, 161])
			};
		}
		catch (e:Dynamic)
		{
			trace('CodenameCompat: failed to convert character $path: $e');
			return null;
		}
	}

	// ------------------------------------------------------------------ stages

	static function luaStr(s:String):String
	{
		return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"';
	}

	static function isCharNode(n:String):Bool
	{
		return switch (n.toLowerCase()) {
			case 'boyfriend' | 'bf' | 'player' | 'girlfriend' | 'gf' | 'dad' | 'opponent': true;
			default: false;
		}
	}

	static function flatten(root:Xml, out:Array<Xml>):Void
	{
		for (e in root.elements())
		{
			var n = e.nodeName.toLowerCase();
			if (n == 'high-memory') flatten(e, out);
			else if (n == 'low-memory') continue;
			else out.push(e);
		}
	}

	/**
	 * Converts data/stages/<name>.xml to a Psych StageFile and writes stages/<name>.lua
	 * (sprites) next to it the first time. Delete the .lua to regenerate it.
	 */
	public static function stageFromXml(stage:String):Dynamic
	{
		var path:String = findModFile('data/stages/' + stage + '.xml');
		if (path == null) return null;
		try
		{
			var root:Xml = Xml.parse(read(path)).firstElement();
			var folder:String = attr(root, 'folder', '');
			if (folder != '' && !folder.endsWith('/')) folder += '/';

			var data:Dynamic = {
				directory: '',
				defaultZoom: num(root.get('zoom'), 1.05),
				isPixelStage: stage.indexOf('school') >= 0 || bool(root, 'pixel', false),
				boyfriend: [770, 100],
				girlfriend: [400, 130],
				opponent: [100, 100],
				hide_girlfriend: false,
				camera_boyfriend: [0, 0],
				camera_opponent: [0, 0],
				camera_girlfriend: [0, 0],
				camera_speed: 1
			};

			var elements:Array<Xml> = [];
			flatten(root, elements);
			var lastChar:Int = -1;
			for (i in 0...elements.length) if (isCharNode(elements[i].nodeName)) lastChar = i;

			var create = new StringBuf();
			var beat = new StringBuf();
			var count = 0;

			for (i in 0...elements.length)
			{
				var e = elements[i];
				var front:Bool = lastChar >= 0 && i > lastChar;
				switch (e.nodeName.toLowerCase())
				{
					case 'boyfriend' | 'bf' | 'player':
						data.boyfriend = [num(e.get('x'), 770), num(e.get('y'), 100)];
						data.camera_boyfriend = [num(e.get('camxoffset'), 0), num(e.get('camyoffset'), 0)];
					case 'girlfriend' | 'gf':
						data.girlfriend = [num(e.get('x'), 400), num(e.get('y'), 130)];
						data.camera_girlfriend = [num(e.get('camxoffset'), 0), num(e.get('camyoffset'), 0)];
					case 'dad' | 'opponent':
						data.opponent = [num(e.get('x'), 100), num(e.get('y'), 100)];
						data.camera_opponent = [num(e.get('camxoffset'), 0), num(e.get('camyoffset'), 0)];

					case 'sprite' | 'spr' | 'sparrow':
						count++;
						var tag = luaStr('cn_' + attr(e, 'name', 'sprite' + count));
						var img = luaStr(folder + attr(e, 'sprite', ''));
						var x = num(e.get('x'), 0), y = num(e.get('y'), 0);
						var anims = [for (a in e.elementsNamed('anim')) a];
						if (anims.length > 0)
						{
							create.add('\tmakeAnimatedLuaSprite($tag, $img, $x, $y)\n');
							for (a in anims)
							{
								var an = luaStr(attr(a, 'name', 'idle'));
								var prefix = luaStr(attr(a, 'anim', ''));
								var fps = num(a.get('fps'), 24);
								var idx = a.get('indices');
								if (idx != null && idx.trim() != '')
									create.add('\taddAnimationByIndices($tag, $an, $prefix, ${luaStr(parseIndices(idx).join(","))}, $fps)\n');
								else
									create.add('\taddAnimationByPrefix($tag, $an, $prefix, $fps, ${bool(a, "loop", false)})\n');
							}
							var firstAnim = luaStr(attr(anims[0], 'name', 'idle'));
							create.add('\tobjectPlayAnimation($tag, $firstAnim, true)\n');

							var type = attr(e, 'type', '').toLowerCase();
							var bops = type.indexOf('beat') >= 0 || e.get('beatInterval') != null;
							for (a in anims) if (attr(a, 'type', '').toLowerCase().indexOf('beat') >= 0) bops = true;
							if (bops)
							{
								var interval = Std.int(num(e.get('beatInterval'), 1));
								if (interval < 1) interval = 1;
								beat.add('\tif curBeat % $interval == 0 then objectPlayAnimation($tag, $firstAnim, true) end\n');
							}
						}
						else
							create.add('\tmakeLuaSprite($tag, $img, $x, $y)\n');

						var sx = num(e.get('scrollx'), num(e.get('scroll'), 1));
						var sy = num(e.get('scrolly'), num(e.get('scroll'), 1));
						create.add('\tsetScrollFactor($tag, $sx, $sy)\n');
						if (e.get('scale') != null || e.get('scalex') != null || e.get('scaley') != null)
						{
							var scx = num(e.get('scalex'), num(e.get('scale'), 1));
							var scy = num(e.get('scaley'), num(e.get('scale'), 1));
							create.add('\tscaleObject($tag, $scx, $scy, ${bool(e, "updateHitbox", false)})\n');
						}
						if (e.get('angle') != null) create.add('\tsetProperty($tag .. ".angle", ${num(e.get("angle"), 0)})\n');
						if (e.get('alpha') != null) create.add('\tsetProperty($tag .. ".alpha", ${num(e.get("alpha"), 1)})\n');
						if (e.get('flipX') != null) create.add('\tsetProperty($tag .. ".flipX", ${bool(e, "flipX", false)})\n');
						if (e.get('antialiasing') != null) create.add('\tsetProperty($tag .. ".antialiasing", ${bool(e, "antialiasing", true)})\n');
						create.add('\taddLuaSprite($tag, $front)\n\n');

					case 'solid' | 'box':
						count++;
						var tag = luaStr('cn_' + attr(e, 'name', 'solid' + count));
						var w = Std.int(num(e.get('width'), 100)), h = Std.int(num(e.get('height'), 100));
						var col = attr(e, 'color', '#FFFFFF').replace('#', '').replace('0x', '');
						create.add('\tmakeLuaSprite($tag, "", ${num(e.get("x"), 0)}, ${num(e.get("y"), 0)})\n');
						create.add('\tmakeGraphic($tag, $w, $h, ${luaStr(col)})\n');
						var sx = num(e.get('scrollx'), num(e.get('scroll'), 1));
						var sy = num(e.get('scrolly'), num(e.get('scroll'), 1));
						create.add('\tsetScrollFactor($tag, $sx, $sy)\n');
						create.add('\taddLuaSprite($tag, $front)\n\n');

					default:
				}
			}

			writeStageLua(path, stage, create.toString(), beat.toString());
			return data;
		}
		catch (e:Dynamic)
		{
			trace('CodenameCompat: failed to convert stage $path: $e');
			return null;
		}
	}

	static function writeStageLua(xmlPath:String, stage:String, create:String, beat:String):Void
	{
		#if sys
		var cut:Int = xmlPath.replace('\\', '/').lastIndexOf('data/stages/');
		if (cut < 0) return;
		var modRoot:String = xmlPath.replace('\\', '/').substr(0, cut);
		var luaPath:String = modRoot + 'stages/' + stage + '.lua';
		if (FileSystem.exists(luaPath)) return;
		try
		{
			if (!FileSystem.exists(modRoot + 'stages')) FileSystem.createDirectory(modRoot + 'stages');
			var lua = new StringBuf();
			lua.add('-- Auto-generated from data/stages/' + stage + '.xml (Codename). Delete this file to regenerate.\n\n');
			lua.add('function onCreate()\n' + create + 'end\n');
			if (beat.length > 0) lua.add('\nfunction onBeatHit()\n' + beat + 'end\n');
			File.saveContent(luaPath, lua.toString());
		}
		catch (e:Dynamic) { trace('CodenameCompat: could not write $luaPath: $e'); }
		#end
	}

	// ------------------------------------------------------------------ freeplay

	static var weeksGenerated:Bool = false;

	/**
	 * Scans every mod folder for Codename songs (songs/<song>/charts/) and writes
	 * weeks/cnauto-*.json so they appear in Freeplay. Story mode stays hidden.
	 */
	public static function generateFreeplayWeeks():Void
	{
		#if MODS_ALLOWED
		if (weeksGenerated) return;
		weeksGenerated = true;

		var roots:Array<String> = [Paths.mods()];
		for (dir in Paths.getModDirectories()) roots.push(Paths.mods(dir + '/'));

		for (root in roots)
		{
			try
			{
				var songsDir = root + 'songs/';
				if (!FileSystem.exists(songsDir) || !FileSystem.isDirectory(songsDir)) continue;

				// group songs by difficulty list (Psych difficulties are per-week)
				var groups:Map<String, Array<Array<Dynamic>>> = new Map();
				var order:Array<String> = [];

				for (folder in FileSystem.readDirectory(songsDir))
				{
					var chartsDir = songsDir + folder + '/charts/';
					if (!FileSystem.exists(chartsDir) || !FileSystem.isDirectory(chartsDir)) continue;
					var low = folder.toLowerCase();
					if (FileSystem.exists(root + 'data/' + low + '/' + low + '.json')) continue; // already has a Psych chart

					var files:Array<String> = [for (f in FileSystem.readDirectory(chartsDir)) if (f.endsWith('.json')) f.substr(0, f.length - 5)];
					if (files.length == 0) continue;

					var meta:Dynamic = readJson(exists(songsDir + folder + '/meta.json') ? songsDir + folder + '/meta.json' : null);
					if (meta == null) meta = {};

					var diffs:Array<String> = [];
					if (meta.difficulties != null)
						for (d in (meta.difficulties : Array<Dynamic>)) if (files.indexOf(Std.string(d)) >= 0 || files.indexOf(Std.string(d).toLowerCase()) >= 0) diffs.push(Std.string(d));
					if (diffs.length == 0)
					{
						for (d in ['easy', 'normal', 'hard']) if (files.indexOf(d) >= 0) diffs.push(d);
						for (f in files) if (diffs.indexOf(f) < 0) diffs.push(f);
					}
					var pretty = [for (d in diffs) d.charAt(0).toUpperCase() + d.substr(1)];
					var diffKey = pretty.join(', ');

					var name:String = str(meta.displayName, str(meta.name, folder));
					if (Paths.formatToSongPath(name) != Paths.formatToSongPath(folder)) name = folder;

					var entry:Array<Dynamic> = [name, str(meta.icon, 'face'), colorArray(meta.color, [146, 113, 253])];
					if (!groups.exists(diffKey)) { groups.set(diffKey, []); order.push(diffKey); }
					groups.get(diffKey).push(entry);
				}

				// keep the mod's own Freeplay order if it has one
				var orderFile = root + 'data/config/freeplaySonglist.txt';
				if (FileSystem.exists(orderFile))
				{
					var wanted:Array<String> = [for (l in File.getContent(orderFile).split('\n')) if (l.trim() != '') Paths.formatToSongPath(l.trim())];
					for (k in groups.keys())
					{
						var list = groups.get(k);
						list.sort(function(a, b) {
							var ia = wanted.indexOf(Paths.formatToSongPath(Std.string(a[0])));
							var ib = wanted.indexOf(Paths.formatToSongPath(Std.string(b[0])));
							if (ia < 0) ia = 9999;
							if (ib < 0) ib = 9999;
							return ia - ib;
						});
					}
				}

				var weeksDir = root + 'weeks/';
				if (FileSystem.exists(weeksDir))
					for (f in FileSystem.readDirectory(weeksDir)) if (f.startsWith('cnauto-')) FileSystem.deleteFile(weeksDir + f);
				if (order.length == 0) continue;
				if (!FileSystem.exists(weeksDir)) FileSystem.createDirectory(weeksDir);

				for (i in 0...order.length)
				{
					var week = {
						songs: groups.get(order[i]),
						weekCharacters: ['dad', 'bf', 'gf'],
						weekBackground: 'stage',
						weekBefore: 'tutorial',
						storyName: 'Codename Songs',
						weekName: 'Codename Songs',
						freeplayColor: [146, 113, 253],
						startUnlocked: true,
						hiddenUntilUnlocked: false,
						hideStoryMode: true,
						hideFreeplay: false,
						difficulties: order[i]
					};
					File.saveContent(weeksDir + 'cnauto-' + i + '.json', Json.stringify(week, '\t'));
				}
			}
			catch (e:Dynamic) { trace('CodenameCompat: freeplay scan failed in $root: $e'); }
		}
		#end
	}
}
