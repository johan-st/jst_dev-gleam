package who

import (
	"fmt"

	"github.com/ichiban/prolog"

	"jst_dev/server/jst_log"
)

var (
	db = `
% user: johan
owns(johan, johan_docs).
in_group(johan, admin).

% Resource properties
is_public(public_docs).

% read if:
%  - Is public
%  - Is owner
%  - Granted read rights by owner
%  - Granted read rights by admin
%  - Is admin

read(User, Res) :-
	is_public(Res);
	owns(User,Res);
	granted_read(User, Res, owns(_,Res));
	granted_read(User, Res, in_group(_,admin));
	in_group(User, admin).

% change if:
%  - Is owner
%  - Granted change rights by owner
%  - Is admin

change(User, Res) :-
	owns(User, Res);
	granted_change(User, Res, owns(_,Res));
	in_group(User, admin).

% delete if:
%  - Is owner
%  - Is admin

delete(User, Res) :-
	owns(User, Res);
	in_group(User, admin).

% create if:
%  - Has create permission in parent
%  - Is admin

create(User, Res) :-
	has_create_permission(User, parent(Res));
	in_group(User, admin).

% Helper predicates
granted_read(_, _, false) :- !, fail.
granted_read(User, Res, true) :- grant(read, User, Res).

granted_change(_, _, false) :- !, fail.
granted_change(User, Res, true) :- grant(change, User, Res).

has_create_permission(User, Parent) :- grant(create, User, Parent).

% Example grants
grant(read, alice, johan_docs).
parent(new_doc) :- root_folder.
root_folder.
`
)

type WhoProlog struct {
	db string
	p  *prolog.Interpreter
	l  *jst_log.Logger
}

// NewProlog initializes a WhoProlog instance with an embedded Prolog database for access control.
// It loads the Prolog rules into a new interpreter and returns the configured WhoProlog or an error if initialization fails.
func NewProlog(l *jst_log.Logger) (*WhoProlog, error) {
	l.Debug("Initializing Prolog interpreter")
	p := prolog.New(nil, nil)

	l.Debug("Loading Prolog database")
	l.Debug("Database contents:\n%s", db)

	err := p.Exec(db)
	if err != nil {
		return nil, fmt.Errorf("initialize database: %w", err)
	}

	who := &WhoProlog{
		db: db,
		p:  p,
		l:  l,
	}

	// Verify the database was loaded correctly
	who.DumpDatabase()

	return who, nil
}

func (w *WhoProlog) Read(user string, res string) (bool, error) {
	allowed, err := w.test(`read(?, ?).`, user, res)
	if err != nil {
		return false, fmt.Errorf("read: %w", err)
	}
	return allowed, nil
}

func (w *WhoProlog) Change(user string, res string) (bool, error) {
	allowed, err := w.test(`change(?, ?).`, user, res)
	if err != nil {
		return false, fmt.Errorf("change: %w", err)
	}
	return allowed, nil
}

func (w *WhoProlog) Delete(user string, res string) (bool, error) {
	allowed, err := w.test(`delete(?, ?).`, user, res)
	if err != nil {
		return false, fmt.Errorf("delete: %w", err)
	}
	return allowed, nil
}

func (w *WhoProlog) Create(user string, res string) (bool, error) {
	allowed, err := w.test(`create(?, ?).`, user, res)
	if err != nil {
		return false, fmt.Errorf("create: %w", err)
	}
	return allowed, nil
}

func (w *WhoProlog) test(predicate string, args ...any) (bool, error) {
	sols, err := w.p.Query(predicate, args...)
	if err != nil {
		return false, fmt.Errorf("query: %w", err)
	}
	defer sols.Close()
	for sols.Next() {
		return true, nil
	}
	if err := sols.Err(); err != nil {
		return false, fmt.Errorf("query next: %w", err)
	}

	return false, nil
}

func (w *WhoProlog) DumpDatabase() {
	w.l.Debug("Prolog Database Contents:")
	w.l.Debug("------------------------")
	w.l.Debug(w.db)
	w.l.Debug("------------------------")
}
