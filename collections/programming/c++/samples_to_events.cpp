Just some slop I coded while watching "This leaked Anthropic interview is crazy".
I don't have C++ LSP or intellisense, so this is mostly off the cuff. There may be some errors and whatnot.

std::vector<Event> samplesToEvents(std::vector<Sample> samples) {
	std::vector<Event> events;

	if (samples.size() == 0) return events;

	for (int i = 1; i < samples.size() i++) {
		int changed_idx = -1

		auto sample = &samples[i]

		if (i > 0) {
			auto prev_sample = &samples[i - 1]

			for (int i = 0; i < prev_sample.stack.size(); i++) {
				if (i == sample.stack.size()) {
					// this sample has started more functions.
					changed_idx = i;
					break;
				}

				if (sample.stack[i] == prev_sample.stack[i]) continue; 

				changed_idx = i;
				break;
			}

			if (changed_idx == -1) continue;

			// remove entries from the stack as needed
			for (int i = current_stack.size() - 1; i >= changed_idx; i--) {
				events.push_back({
					sample.ts, // this time is 'exclusive'. Meaning that it ended t - elipson before any start events at htis time
					current_stack.pop_back(),
					"end"
				})
			}
		}
		
		// add new entries as needed
		for (int i = changed_idx; i < sample.stack.size(); i++) {
			events.push_back({sample.ts, sample[i], "start"})
		}
	}

	for (auto fn : samples.back().stack) {
		events.push_back({sample.ts, fn,  "end"})
	}

	return events;
}
