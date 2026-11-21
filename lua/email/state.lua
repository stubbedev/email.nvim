local state = {}
state.total = nil
state.exhausted = false
state.pages = {}
state.threads = {}
state.marked = {}
state.kept = {}
state.unread = {}
state.reading = false
state.win = {}
state.buf = {}
state.sidebar_rows = {}
state.load_generation = 0
state.polling = false
state.busy = 0
return state
