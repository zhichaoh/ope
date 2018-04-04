namespace :ope do
  desc "Deal with OPE specific startup and configuration tasks"
  
  task :init_auditing => :environment do
    # Add the audit scheme/etc...
	ActiveRecord::Base.connection.execute( <<-SQLSTRING

CREATE SCHEMA IF NOT EXISTS ope_audit;
REVOKE ALL ON SCHEMA ope_audit FROM public;

COMMENT ON SCHEMA ope_audit IS 'Database sync code for Open Prison Education project';

CREATE OR REPLACE FUNCTION ope_audit.jsonb_minus ( arg1 jsonb, arg2 jsonb )
 RETURNS jsonb
AS $$

SELECT 
	COALESCE(json_object_agg(
        key,
        CASE
            -- if the value is an object and the value of the second argument is
            -- not null, we do a recursion
            WHEN jsonb_typeof(value) = 'object' AND arg2 -> key IS NOT NULL 
			THEN ope_audit.jsonb_minus(value, arg2 -> key)
            -- for all the other types, we just return the value
            ELSE value
        END
    ), '{}')::jsonb
FROM 
	jsonb_each(arg1)
WHERE 
	arg1 -> key <> arg2 -> key 
	OR arg2 -> key IS NULL

$$ LANGUAGE SQL;

DROP OPERATOR IF EXISTS - ( jsonb, jsonb );

CREATE OPERATOR - (
    PROCEDURE = ope_audit.jsonb_minus,
    LEFTARG   = jsonb,
    RIGHTARG  = jsonb );

SQLSTRING
	)
	
	# Run second part - split so operator can be in place when next statements run
	ActiveRecord::Base.connection.execute( <<-SQLSTRING
	
CREATE TABLE IF NOT EXISTS ope_audit.logged_actions (
    event_id bigserial primary key,
    schema_name text not null,
    table_name text not null,
    relid oid not null,
    session_user_name text,
    action_tstamp_tx TIMESTAMP WITH TIME ZONE NOT NULL,
    action_tstamp_stm TIMESTAMP WITH TIME ZONE NOT NULL,
    action_tstamp_clk TIMESTAMP WITH TIME ZONE NOT NULL,
    transaction_id bigint,
    application_name text,
    client_addr inet,
    client_port integer,
    client_query text,
    action TEXT NOT NULL CHECK (action IN ('I','D','U', 'T')),
    row_data jsonb,
    changed_fields jsonb,
    statement_only boolean not null
);

REVOKE ALL ON ope_audit.logged_actions FROM public;

COMMENT ON TABLE ope_audit.logged_actions IS 'History of auditable actions on audited tables, from audit.if_modified_func()';
COMMENT ON COLUMN ope_audit.logged_actions.event_id IS 'Unique identifier for each auditable event';
COMMENT ON COLUMN ope_audit.logged_actions.schema_name IS 'Database schema audited table for this event is in';
COMMENT ON COLUMN ope_audit.logged_actions.table_name IS 'Non-schema-qualified table name of table event occured in';
COMMENT ON COLUMN ope_audit.logged_actions.relid IS 'Table OID. Changes with drop/create. Get with ''tablename''::regclass';
COMMENT ON COLUMN ope_audit.logged_actions.session_user_name IS 'Login / session user whose statement caused the audited event';
COMMENT ON COLUMN ope_audit.logged_actions.action_tstamp_tx IS 'Transaction start timestamp for tx in which audited event occurred';
COMMENT ON COLUMN ope_audit.logged_actions.action_tstamp_stm IS 'Statement start timestamp for tx in which audited event occurred';
COMMENT ON COLUMN ope_audit.logged_actions.action_tstamp_clk IS 'Wall clock time at which audited event''s trigger call occurred';
COMMENT ON COLUMN ope_audit.logged_actions.transaction_id IS 'Identifier of transaction that made the change. May wrap, but unique paired with action_tstamp_tx.';
COMMENT ON COLUMN ope_audit.logged_actions.client_addr IS 'IP address of client that issued query. Null for unix domain socket.';
COMMENT ON COLUMN ope_audit.logged_actions.client_port IS 'Remote peer IP port address of client that issued query. Undefined for unix socket.';
COMMENT ON COLUMN ope_audit.logged_actions.client_query IS 'Top-level query that caused this auditable event. May be more than one statement.';
COMMENT ON COLUMN ope_audit.logged_actions.application_name IS 'Application name set when this audit event occurred. Can be changed in-session by client.';
COMMENT ON COLUMN ope_audit.logged_actions.action IS 'Action type; I = insert, D = delete, U = update, T = truncate';
COMMENT ON COLUMN ope_audit.logged_actions.row_data IS 'Record value. Null for statement-level trigger. For INSERT this is the new tuple. For DELETE and UPDATE it is the old tuple.';
COMMENT ON COLUMN ope_audit.logged_actions.changed_fields IS 'New values of fields changed by UPDATE. Null except for row-level UPDATE events.';
COMMENT ON COLUMN ope_audit.logged_actions.statement_only IS '''t'' if ope_audit event is from an FOR EACH STATEMENT trigger, ''f'' for FOR EACH ROW';

CREATE INDEX IF NOT EXISTS logged_actions_relid_idx ON ope_audit.logged_actions(relid);
CREATE INDEX IF NOT EXISTS logged_actions_action_tstamp_tx_stm_idx ON ope_audit.logged_actions(action_tstamp_stm);
CREATE INDEX IF NOT EXISTS logged_actions_action_idx ON ope_audit.logged_actions(action);
CREATE INDEX IF NOT EXISTS logged_actions_table_name_idx ON ope_audit.logged_actions(table_name);

CREATE OR REPLACE FUNCTION ope_audit.if_modified_func() RETURNS TRIGGER AS $body$
DECLARE
    ope_audit_row ope_audit.logged_actions;
    include_values boolean;
    log_diffs boolean;
    h_old jsonb;
    h_new jsonb;
    excluded_cols text[] = ARRAY[]::text[];
BEGIN
    IF TG_WHEN <> 'AFTER' THEN
        RAISE EXCEPTION 'ope_audit.if_modified_func() may only run as an AFTER trigger';
    END IF;

    ope_audit_row = ROW(
        nextval('ope_audit.logged_actions_event_id_seq'), -- event_id
        TG_TABLE_SCHEMA::text,                        -- schema_name
        TG_TABLE_NAME::text,                          -- table_name
        TG_RELID,                                     -- relation OID for much quicker searches
        session_user::text,                           -- session_user_name
        current_timestamp,                            -- action_tstamp_tx
        statement_timestamp(),                        -- action_tstamp_stm
        clock_timestamp(),                            -- action_tstamp_clk
        txid_current(),                               -- transaction ID
        current_setting('application_name'),          -- client application
        inet_client_addr(),                           -- client_addr
        inet_client_port(),                           -- client_port
        current_query(),                              -- top-level query or queries (if multistatement) from client
        substring(TG_OP,1,1),                         -- action
        NULL, NULL,                                   -- row_data, changed_fields
        'f'                                           -- statement_only
        );

    IF NOT TG_ARGV[0]::boolean IS DISTINCT FROM 'f'::boolean THEN
        ope_audit_row.client_query = NULL;
    END IF;

    IF TG_ARGV[1] IS NOT NULL THEN
        excluded_cols = TG_ARGV[1]::text[];
    END IF;

    IF (TG_OP = 'UPDATE' AND TG_LEVEL = 'ROW') THEN
        ope_audit_row.row_data = to_jsonb(OLD.*);
        ope_audit_row.changed_fields =  (to_jsonb(NEW.*) - to_jsonb(ope_audit_row.row_data)) - to_jsonb(excluded_cols);
        IF ope_audit_row.changed_fields = NULL THEN
            -- All changed fields are ignored. Skip this update.
            RETURN NULL;
        END IF;
    ELSIF (TG_OP = 'DELETE' AND TG_LEVEL = 'ROW') THEN
        ope_audit_row.row_data = to_jsonb(OLD.*) - to_jsonb(excluded_cols);
    ELSIF (TG_OP = 'INSERT' AND TG_LEVEL = 'ROW') THEN
        ope_audit_row.row_data = to_jsonb(NEW.*) - to_jsonb(excluded_cols);
    ELSIF (TG_LEVEL = 'STATEMENT' AND TG_OP IN ('INSERT','UPDATE','DELETE','TRUNCATE')) THEN
        ope_audit_row.statement_only = 't';
    ELSE
        RAISE EXCEPTION '[ope_audit.if_modified_func] - Trigger func added as trigger for unhandled case: %, %',TG_OP, TG_LEVEL;
        RETURN NULL;
    END IF;
    INSERT INTO ope_audit.logged_actions VALUES (ope_audit_row.*);
    RETURN NULL;
END;
$body$
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public;


COMMENT ON FUNCTION ope_audit.if_modified_func() IS $body$
Track changes to a table at the statement and/or row level.

Optional parameters to trigger in CREATE TRIGGER call:

param 0: boolean, whether to log the query text. Default 't'.

param 1: text[], columns to ignore in updates. Default [].

         Updates to ignored cols are omitted from changed_fields.

         Updates with only ignored cols changed are not inserted
         into the ope_audit log.

         Almost all the processing work is still done for updates
         that ignored. If you need to save the load, you need to use
         WHEN clause on the trigger instead.

         No warning or error is issued if ignored_cols contains columns
         that do not exist in the target table. This lets you specify
         a standard set of ignored columns.

There is no parameter to disable logging of values. Add this trigger as
a 'FOR EACH STATEMENT' rather than 'FOR EACH ROW' trigger if you do not
want to log row values.

Note that the user name logged is the login role for the session. The ope_audit trigger
cannot obtain the active role because it is reset by the SECURITY DEFINER invocation
of the ope_audit trigger its self.
$body$;

CREATE OR REPLACE FUNCTION ope_audit.ope_audit_table(target_table regclass, ope_audit_rows boolean, ope_audit_query_text boolean, ignored_cols text[]) RETURNS void AS $body$
DECLARE
  stm_targets text = 'INSERT OR UPDATE OR DELETE OR TRUNCATE';
  _q_txt text;
  _ignored_cols_snip text = '';
BEGIN
    EXECUTE 'DROP TRIGGER IF EXISTS ope_audit_trigger_row ON ' || target_table;
    EXECUTE 'DROP TRIGGER IF EXISTS ope_audit_trigger_stm ON ' || target_table;

    IF ope_audit_rows THEN
        IF array_length(ignored_cols,1) > 0 THEN
            _ignored_cols_snip = ', ' || quote_literal(ignored_cols);
        END IF;
        _q_txt = 'CREATE TRIGGER ope_audit_trigger_row AFTER INSERT OR UPDATE OR DELETE ON ' ||
                 target_table ||
                 ' FOR EACH ROW EXECUTE PROCEDURE ope_audit.if_modified_func(' ||
                 quote_literal(ope_audit_query_text) || _ignored_cols_snip || ');';
        RAISE NOTICE '%',_q_txt;
        EXECUTE _q_txt;
        stm_targets = 'TRUNCATE';
    ELSE
    END IF;

    _q_txt = 'CREATE TRIGGER ope_audit_trigger_stm AFTER ' || stm_targets || ' ON ' ||
             target_table ||
             ' FOR EACH STATEMENT EXECUTE PROCEDURE ope_audit.if_modified_func('||
             quote_literal(ope_audit_query_text) || ');';
    RAISE NOTICE '%',_q_txt;
    EXECUTE _q_txt;

END;
$body$
language 'plpgsql';

CREATE OR REPLACE FUNCTION ope_audit.ope_audit_table_disable(target_table regclass) RETURNS void AS $body$
DECLARE
  stm_targets text = 'INSERT OR UPDATE OR DELETE OR TRUNCATE';
  _q_txt text;
  _ignored_cols_snip text = '';
BEGIN
    EXECUTE 'DROP TRIGGER IF EXISTS ope_audit_trigger_row ON ' || target_table;
    EXECUTE 'DROP TRIGGER IF EXISTS ope_audit_trigger_stm ON ' || target_table;
END;
$body$
language 'plpgsql';

COMMENT ON FUNCTION ope_audit.ope_audit_table(regclass, boolean, boolean, text[]) IS $body$
Add auditing support to a table.

Arguments:
   target_table:     Table name, schema qualified if not on search_path
   ope_audit_rows:       Record each row change, or only audit at a statement level
   ope_audit_query_text: Record the text of the client query that triggered the audit event?
   ignored_cols:     Columns to exclude from update diffs, ignore updates that change only ignored cols.
$body$;

-- Pg doesn't allow variadic calls with 0 params, so provide a wrapper
CREATE OR REPLACE FUNCTION ope_audit.ope_audit_table(target_table regclass, ope_audit_rows boolean, ope_audit_query_text boolean) RETURNS void AS $body$
SELECT ope_audit.ope_audit_table($1, $2, $3, ARRAY[]::text[]);
$body$ LANGUAGE SQL;

-- And provide a convenience call wrapper for the simplest case
-- of row-level logging with no excluded cols and query logging enabled.
--
CREATE OR REPLACE FUNCTION ope_audit.ope_audit_table(target_table regclass) RETURNS void AS $$
SELECT ope_audit.ope_audit_table($1, BOOLEAN 't', BOOLEAN 't');
$$ LANGUAGE 'sql';

COMMENT ON FUNCTION ope_audit.ope_audit_table(regclass) IS $body$
Add ope_auditing support to the given table. Row-level changes will be logged with full client query text. No cols are ignored.
$body$;
	
	
SQLSTRING
	)
  end
  
  task :enable_auditing => :environment do
	# Audit all tables in the db
	ActiveRecord::Base.connection.tables.each do |table|
	  begin
		# Don't add triggers to certain tables that we don't want to merge
		# TODO - ruby way to test against an array of table names?
		if (table != "delayed_jobs" && table != "failed_jobs")
			ActiveRecord::Base.connection.execute("select ope_audit.ope_audit_table('#{table}');")
			print "#{table} ENABLED, "
		else
			# Make sure to remove trigger if it exists
			ActiveRecord::Base.connection.execute("select ope_audit.ope_audit_table_disable('#{table}');")
			print "#{table} DISABLED, "
		end
	  rescue
		print "#{table} -- ERROR --, "
	  end
	end
  end

  task :startup do
    # Make sure we have info in our environment
    if (ENV["CANVAS_LMS_ACCOUNT_NAME"] || "").empty?
        puts "==== ERR - CANVAS_LMS_ACCOUNT_NAME empty ===="
        ENV["CANVAS_LMS_ACCOUNT_NAME"] = "Open Prison Education"
    end

    if (ENV["CANVAS_LMS_ADMIN_EMAIL"] || "").empty?
        puts "==== ERR - CANVAS_LMS_ADMIN_EMAIL empty ===="
        ENV["CANVAS_LMS_ADMIN_EMAIL"] = "admin@ed"
    end

    if (ENV["CANVAS_LMS_ADMIN_PASSWORD"] || "").empty?
        puts "==== ERR - CANVAS_LMS_ADMIN_PASSWORD empty ===="
        ENV["CANVAS_LMS_ADMIN_PASSWORD"] = "changeme331"
    end
    
    if (ENV["CANVAS_LMS_STATS_COLLECTION"] || "").empty?
        ENV["CANVAS_LMS_STATS_COLLECTION"] = "opt_out"
    end

    # See if file .db_init_done exists - if it doesn't, run db:initial_setup
    db_init_done_file = "/usr/src/app/tmp/db_init_done"
    if File.file?(db_init_done_file) == true
        puts "==== DB Init done - skipping ===="
    else
        puts "==== Canvas DB does NOT exist, creating ===="
        Rake::Task['db:initial_setup'].invoke
        # Save the file so we show db init finished
        begin
            File.open(db_init_done_file, 'w') do |f|
                f.puts "DB Init Run"
            end
        rescue
            puts "=== ERROR - writing #{db_init_done_file}"
        end
        puts "==== END Canvas DB does NOT exist, creating ===="
    end
    
    puts "==== OPE:starup_stage2 ===="
    Rake::Task['ope:startup_stage2'].invoke
    puts "==== END OPE:starup_stage2 ===="

  end
  
  task :startup_stage2 => :environment do
    # Do all startup tasks
    
    # ==== Init DB if not already done
    db_changed = 0
    
    # ==== Run db migrate	
    # Get the number of schema migrations so we can see if db:migrate changes anything
    pre_migrations = 0
    post_migrations = 0
    
    sql_row = ActiveRecord::Base.connection.exec_query("select count(*) as cnt from schema_migrations")
    sql_row.each do |row|
        pre_migrations = row["cnt"].to_i
    end
		
    puts "==== Running db:migrate ===="
    Rake::Task['db:migrate'].invoke
    puts "==== END Running db:migrate ===="
    
    # Get the number after migrations
    sql_row = ActiveRecord::Base.connection.exec_query("select count(*) as cnt from schema_migrations")
    sql_row.each do |row|
        post_migrations = row["cnt"].to_i
    end

    if (pre_migrations != post_migrations)
        db_changed = 1
    end

    # Make sure that the assets are properly compiled (run this each time as a migrate may require a recompile)
    if (db_changed == 1)
        puts "==== DB Migrations detected ===="
        # Rake::Task['canvas:compile_assets'].invoke
        # NOTE: Shouldn't need recompile - should have been done in docker build, just do brand_configs
        puts "====> brand_configs:generate_and_upload_all..."
        Rake::Task['brand_configs:generate_and_upload_all'].invoke
        puts "====> END brand_configs:generate_and_upload_all..."
    else
        puts "====> No DB migrations detected"
    end
    
    puts "==== Resetting encryption key hash ===="
    Rake::Task['db:reset_encryption_key_hash'].invoke
    puts "==== END Resetting encryption key hash ===="


    # Build db to track changes to data
    puts "==== ope:init_auditing ===="
    Rake::Task['ope:init_auditing'].invoke
    puts "==== END ope:init_auditing ===="
    
    # Load the unique sequence range for this install to avoid ID conflicts
    puts "==== Running ope:set_sequence_range ===="
    Rake::Task['ope:set_sequence_range'].invoke
    puts "==== END Running ope:set_sequence_range ===="

    # Make sure that we have loaded and enabled the audit stuff
    puts "==== ope:enabling audting ===="
    Rake::Task['ope:enable_auditing'].invoke
    puts "==== END ope:enabling audting ===="

    # Make sure admin account exists - should always be id 1
    #puts "==== Ensuring Admin Account Exists ===="

    #account = Account.find_by(id: 1)
    #if (account)
    #    puts "==== Admin account exists ===="
    #else
    #    puts "==== Admin account not found - loading initial data ===="
    #    #Rake::Task['db:initial_setup'].invoke
    #    Rake::Task['db:load_initial_data'].invoke
    #    puts "==== END Admin account not found - loading initial data ===="
    #end

    #account = Account.find_by(id: 1)
    #if (account)
    #    puts "==== Admin account exists ===="
    #else
    #    puts "==== Admin account not found - creating ===="
    #    ActiveRecord::Base.transaction do
    #      begin
    #          # Create the user
    #          account = Account.create!(
    #              id: 1,
    #              name: acct_name,
    #          )
    #          user = User.create!(
    #              name: acct_name,
    #              short_name: acct_name,
    #              sortable_name: acct_name
    #          )
    #          # Create the pseudonym for login
    #          pseudonym = Pseudonym.create!(
    #              :account => account,
    #              :unique_id => acct_email,
    #              :user => user
    #          )
    #          pseudonym.password = pseudonym.password_confirmation = acct_pw
    #          pseudonym.save!
    #
    #          puts "==== Admin Account Created - login with #{acct_email} ===="
    #      rescue => e
    #          puts "====> ERROR Creating Admin Account ===="
    #          puts e
    #          raise ActiveRecord::Rollback
    #      end
    #    end
    #end
    #puts "==== END Ensuring Admin Account Exists ===="
    
    # Set canvas options
    admin_account = Account.find_by(name: ENV["CANVAS_LMS_ACCOUNT_NAME"] )
    site_admin_account = Account.find_by(name: "Site Admin" )
    if (admin_account && site_admin_account)
        puts "==== Setting Canvas Config Settings ===="

        admin_account.default_time_zone = "Pacific Time (US & Canada)"
        site_admin_account.default_time_zone = "Pacific Time (US & Canada)"

        # Disable web services
        admin_account.disable_service("google_docs_previews")
        admin_account.disable_service("skype")
        admin_account.disable_service("delicious")
        site_admin_account.disable_service("google_docs_previews")
        site_admin_account.disable_service("skype")
        site_admin_account.disable_service("delicious")

        # Allow admin account to change / set passwords - needed by SMC
        site_admin_account.settings[:admins_can_change_passwords] = admin_account.settings[:admins_can_change_passwords] = true
        site_admin_account.settings[:edit_institution_email] = admin_account.settings[:edit_institution_email] = false
        site_admin_account.settings[:admins_can_view_notifications] = admin_account.settings[:admins_can_view_notifications] = true
        site_admin_account.settings[:allow_invitation_previews] = admin_account.settings[:allow_invitation_previews] = false
        site_admin_account.settings[:allow_sending_scores_in_emails] = admin_account.settings[:allow_sending_scores_in_emails] = false
        site_admin_account.settings[:author_email_in_notifications] = admin_account.settings[:author_email_in_notifications] = false
        site_admin_account.settings[:enable_alerts] = admin_account.settings[:enable_alerts] = false
        site_admin_account.settings[:enable_portfolios] = admin_account.settings[:enable_portfolios] = false
        site_admin_account.settings[:enable_offline_web_export] = admin_account.settings[:enable_offline_web_export] = false
        site_admin_account.settings[:enable_profiles] = admin_account.settings[:enable_profiles] = false
        site_admin_account.settings[:enable_gravatar] = admin_account.settings[:enable_gravatar] = false
        site_admin_account.settings[:enable_turnitin] = admin_account.settings[:enable_turnitin] = false
        site_admin_account.settings[:global_includes] = admin_account.settings[:global_includes] = false
        site_admin_account.settings[:include_students_in_global_survey] = admin_account.settings[:include_students_in_global_survey] = false
        site_admin_account.settings[:lock_all_announcements] = admin_account.settings[:lock_all_announcements] = true
        site_admin_account.settings[:mfa_settings] = admin_account.settings[:mfa_settings] = "disabled"
        site_admin_account.settings[:no_enrollments_can_create_courses] = admin_account.settings[:no_enrollments_can_create_courses] = false
        site_admin_account.settings[:open_registration] = admin_account.settings[:open_registration] = false
        site_admin_account.settings[:prevent_course_renaming_by_teachers] = admin_account.settings[:prevent_course_renaming_by_teachers] = false
        site_admin_account.settings[:restrict_quiz_questions] = admin_account.settings[:restrict_quiz_questions] = true
        site_admin_account.settings[:restrict_student_future_listing] = admin_account.settings[:restrict_student_future_listing] = false
        site_admin_account.settings[:restrict_student_future_view] = admin_account.settings[:restrict_student_future_view] = true
        site_admin_account.settings[:restrict_student_past_view] = admin_account.settings[:restrict_student_past_view] = true
        site_admin_account.settings[:show_scheduler] = admin_account.settings[:show_scheduler] = false
        site_admin_account.settings[:students_can_create_courses] = admin_account.settings[:students_can_create_courses] = false
        site_admin_account.settings[:sub_accunt_includes] = admin_account.settings[:sub_accunt_includes] = false
        site_admin_account.settings[:teachers_can_create_courses] = admin_account.settings[:teachers_can_create_courses] = false
        site_admin_account.settings[:users_can_edit_name] = admin_account.settings[:users_can_edit_name] = false
        site_admin_account.settings[:login_handle_name] = admin_account.settings[:login_handle_name] = "Student ID (default s + DOC number - e.g. s113412)"
        site_admin_account.settings[:self_enrollment] = admin_account.settings[:self_enrollment] = "Never"



        # Default storage quotas
        admin_account.default_storage_quota_mb=5000
        admin_account.default_user_storage_quota_mb=1
        admin_account.default_group_storage_quota_mb=1
        site_admin_account.default_storage_quota_mb=5000
        site_admin_account.default_user_storage_quota_mb=1
        site_admin_account.default_group_storage_quota_mb=1
        
        # Lock down permissions - TODO
        admin_account.available_course_roles do |r|
            puts "Role #{r}"
        end
        #r = admin_account.get_course_role_by_name("StudentEnrollment")
        #r[:permissions][:create_collaborations][:enabled]=false
        #r.save


        admin_account.save
        site_admin_account.save
    else
        puts "==== ERROR - Unable to find root account! ===="
    end

    # Reset password for admin user to pw provided in the environment
    puts "==== Resetting admin password ===="
    p = Pseudonym.find_by unique_id: ENV["CANVAS_LMS_ADMIN_EMAIL"]
    if p
        p.password = p.password_confirmation = ENV["CANVAS_LMS_ADMIN_PASSWORD"]
        p.save!
    else
        puts "====> ERROR - no admin user found! ===="
    end
    puts "==== END Resetting admin password ===="

  end
  
  task :set_sequence_range => :environment do
    # If no range defined, create one and set it
    range_file = "/usr/src/app/tmp/db_sequence_range"
    rangestart = 0
    # Use an epoch time (in minutes which is about 2/14/18) when we calculate a new rangestart
    epoch_time = 25310582 # 24675840
    school_id_range_max = 999_999  # This times the local_id_range is the full db range
    local_id_range = 1_000_000_000 # Use this to bump the schoo_id range up
    
    
    # Old values
    # *_000_000_000_000_000_000 - Shard Range
    # 0_***_***_*00_000_000_000 - School Range
    # 0_000_000_0**_***_***_*** - Local ID Range

    # Javascript - uses float to store ints, so max is 53 bits instead of 64?
    # 9_223_372_036_854_775_807 - Normal Max 64 bit int - for every language but JScript
    # 0_009_007_199_254_740_991 - Max safe int for jscript (jscript, you suck in so many ways)
    # 0_00*_000_000_000_000_000 - We push DB shards to this digit (0-9 shards possible)
    # 0_000_***_***_000_000_000 - Auto set School Range based on time of initial startup (rolls over after 2 years)
    # 0_000_000_000_***_***_*** - Leaves 1 bil ids for local tables and doesn't loose data due to jscript


    # Load the current value if it exists
    if File.file?(range_file) == true
        File.open(range_file, 'r') do |f|
            line = f.gets
            rangestart = line.to_i
        end
        puts "===== Range already defined #{rangestart}"
    end
    
    if rangestart <= 0 or rangestart > school_id_range_max
        # Calculate new range
        puts "===== Invalid range #{rangestart}, calculating new range"
        rangestart = Time.now.to_i / 60 # Seconds since 1970 - convert to minutes
        rangestart = rangestart - epoch_time # Subtract epoch to start range at 0
        # Make sure we are 1 to school_id_range_max
        while rangestart >= school_id_range_max
            # If we overflow, just reset the range, odds of id conflict on the second or
            # third time through are extremely small
            rangestart = (rangestart - school_id_range_max).abs
        end
        if rangestart < 0
            puts "=====> ERROR ERROR ERROR - rangestart calculated to negative number!!!!!"
            rangestart = 1
        end
        
        # Store the range in a file
        begin
            File.open(range_file, 'w') do |f|
                f.puts rangestart
            end
        rescue
            puts "Error writing DB ID range to file #{range_file}"
        end
    end
    
    # Bump the range up to to the school range - e.g. shift it left into the billions/trillions area
    rangestart_full = rangestart * local_id_range		

    # Update the database sequences to use this range
    ActiveRecord::Base.connection.tables.each do |table|  
        begin
            last_seq = 0
            seq_row = ActiveRecord::Base.connection.exec_query("select nextval('#{table}_id_seq'::regclass) as nv")
            seq_row.each do |row|
                last_seq = row["nv"].to_i
            end
            print "#{table} #{last_seq} -> #{rangestart_full}, "
            if (last_seq < rangestart_full || last_seq >= rangestart_full + local_id_range )
                # puts "=====> Last sequence outside of current range #{table} #{last_seq} -> #{rangestart_full}"
                ActiveRecord::Base.connection.execute("ALTER SEQUENCE #{table}_id_seq RESTART WITH #{rangestart_full}")
            end
        rescue
            puts "#{table} ERROR, "
        end
    end

    # Set the logged_actions table sequence too
    last_seq = 0
    seq_row = ActiveRecord::Base.connection.exec_query("select nextval('ope_audit.logged_actions_event_id_seq'::regclass) as nv")
    seq_row.each do |row|
        last_seq = row["nv"].to_i
    end
    if (last_seq < rangestart_full || last_seq >= rangestart_full + local_id_range )
        #puts "=====> Last sequence outside of current range logged_actions_event_id_seq #{last_seq} -> #{rangestart_full}"
        ActiveRecord::Base.connection.execute("ALTER SEQUENCE ope_audit.logged_actions_event_id_seq RESTART WITH #{rangestart_full}")
    end

    puts "=====> Finished setting sequence range to #{rangestart_full}"
    # Make sure to change the constraint on the version tables so they don't blow up with big ids
    begin
        ActiveRecord::Base.connection.exec_query("alter table versions_0 drop constraint versions_0_versionable_id_check;")
    rescue
    end
    begin
        ActiveRecord::Base.connection.exec_query("alter table versions_1 drop constraint versions_1_versionable_id_check;")
    rescue
    end
  
  end
    
end