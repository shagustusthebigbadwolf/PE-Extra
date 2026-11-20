package;

using StringTools;

/**
 * ManiaConverter (Shagustus) - remaps charts between key counts.
 *
 * Lanes are matched by direction using the key layouts in data/note_colors.txt
 * (left/down/up/right/center + left2, down3, ...), so a 9K chart folds onto 4K
 * the way a player would expect, and 4K spreads across both hands on 6K/8K/9K.
 *
 * Used by:
 *   - the "Force Key Count" gameplay changer (any chart -> chosen key count)
 *   - CodenameCompat, when a Codename strumline uses a different keyCount
 */
class ManiaConverter
{
	public static inline var MIN_KEYS:Int = 1;

	/** Optional hand-made overrides: "from>to" => target lane for each source lane. */
	public static var TABLES:Map<String, Array<Int>> = new Map();

	static var layouts:Array<Array<String>> = null;

	static var FALLBACKS:Map<String, Array<String>> = [
		'left' => ['down', 'center', 'up', 'right'],
		'right' => ['up', 'center', 'down', 'left'],
		'down' => ['center', 'left', 'up', 'right'],
		'up' => ['center', 'right', 'down', 'left'],
		'center' => ['up', 'down', 'left', 'right']
	];

	public static function maxKeys():Int
	{
		return Note.MAX_KEYS;
	}

	public static function clampKeys(keys:Int):Int
	{
		if (keys < MIN_KEYS) return MIN_KEYS;
		if (keys > maxKeys()) return maxKeys();
		return keys;
	}

	static function getLayout(keys:Int):Array<String>
	{
		if (layouts == null)
		{
			try { layouts = CoolUtil.coolArrayTextFile(Paths.txt('note_colors')); }
			catch (e:Dynamic) { layouts = []; }
		}
		if (keys < 1 || keys > layouts.length) return null;
		return layouts[keys - 1];
	}

	static function baseDir(name:String):String
	{
		var s = name.toLowerCase().trim();
		while (s.length > 0 && s.charCodeAt(s.length - 1) >= '0'.code && s.charCodeAt(s.length - 1) <= '9'.code)
			s = s.substr(0, s.length - 1);
		return s;
	}

	static function proportional(lane:Int, from:Int, to:Int):Int
	{
		var mapped:Int = Std.int(Math.floor((lane + 0.5) * to / from));
		if (mapped < 0) mapped = 0;
		if (mapped > to - 1) mapped = to - 1;
		return mapped;
	}

	/** Maps one lane from a `from`-key layout to a `to`-key layout. */
	public static function mapLane(lane:Int, from:Int, to:Int):Int
	{
		if (from == to) return lane;
		if (from < 1 || to < 1) return 0;
		lane = lane % from;

		var table = TABLES.get(from + '>' + to);
		if (table != null && lane < table.length) return table[lane];

		var src = getLayout(from);
		var dst = getLayout(to);
		if (src == null || dst == null || lane >= src.length) return proportional(lane, from, to);

		var dir = baseDir(src[lane]);
		var same:Array<Int> = [for (i in 0...src.length) if (baseDir(src[i]) == dir) i];
		var occ = same.indexOf(lane);
		var ratio:Float = 0;
		if (same.length > 1) ratio = occ / (same.length - 1);
		else ratio = switch (dir) {
			case 'left' | 'down': 0;
			case 'center': 0.5;
			default: 1;
		};

		var order = [dir];
		var fb = FALLBACKS.get(dir);
		if (fb != null) for (f in fb) order.push(f);
		for (d in order)
		{
			var cands:Array<Int> = [for (i in 0...dst.length) if (baseDir(dst[i]) == d) i];
			if (cands.length > 0) return cands[Math.round(ratio * (cands.length - 1))];
		}
		return proportional(lane, from, to);
	}

	/**
	 * Converts every note of a PE Extra song (both sides, including per-section
	 * key changes) to `toKeys`. Notes that land on the same lane at the same time
	 * are merged, keeping the longer sustain. Returns false if nothing changed.
	 */
	public static function convertSong(song:SwagSong, toKeys:Int):Bool
	{
		if (song == null || song.notes == null) return false;
		toKeys = clampKeys(toKeys);

		var curPlayer:Int = song.playerKeyAmount != null ? song.playerKeyAmount : 4;
		var curOpp:Int = song.opponentKeyAmount != null ? song.opponentKeyAmount : 4;
		var anyChange = curPlayer != toKeys || curOpp != toKeys;

		for (sec in song.notes)
		{
			if (sec == null) continue;
			if (sec.changeKeys == true)
			{
				if (sec.playerKeys != null) curPlayer = sec.playerKeys;
				if (sec.opponentKeys != null) curOpp = sec.opponentKeys;
				if (curPlayer != toKeys || curOpp != toKeys) anyChange = true;
			}
			var leftKeys = sec.mustHitSection ? curPlayer : curOpp;
			var rightKeys = sec.mustHitSection ? curOpp : curPlayer;

			var out:Array<Array<Dynamic>> = [];
			var seen:Map<String, Int> = new Map();
			if (sec.sectionNotes != null)
			{
				for (n in sec.sectionNotes)
				{
					var data:Int = Std.int(n[1]);
					if (data < 0) { out.push(n); continue; }
					var onLeft = data < leftKeys;
					var lane = onLeft ? data : (data - leftKeys) % rightKeys;
					var srcKeys = onLeft ? leftKeys : rightKeys;
					var newLane = mapLane(lane, srcKeys, toKeys);
					var newData = onLeft ? newLane : toKeys + newLane;

					var copy:Array<Dynamic> = n.copy();
					copy[1] = newData;
					var key = Std.string(Math.round(n[0])) + ':' + newData;
					if (seen.exists(key))
					{
						var i = seen.get(key);
						var oldSus:Float = out[i][2] != null ? out[i][2] : 0;
						var newSus:Float = copy[2] != null ? copy[2] : 0;
						if (newSus > oldSus) out[i] = copy;
						continue;
					}
					seen.set(key, out.length);
					out.push(copy);
				}
			}
			sec.sectionNotes = out;
			sec.playerKeys = toKeys;
			sec.opponentKeys = toKeys;
		}
		song.playerKeyAmount = toKeys;
		song.opponentKeyAmount = toKeys;
		return anyChange;
	}

	/** Applies the "Force Key Count" gameplay changer. Call right after PlayState.SONG is set. */
	public static function applyForcedKeys(song:SwagSong):Void
	{
		var forced:Dynamic = ClientPrefs.getGameplaySetting('forcekeys', 'Off');
		if (forced == null) return;
		var str = Std.string(forced);
		if (str == 'Off') return;
		var keys:Null<Int> = Std.parseInt(str);
		if (keys != null) convertSong(song, keys);
	}
}
