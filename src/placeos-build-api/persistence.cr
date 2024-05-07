require "db"
require "sqlite3"

module PlaceOS::Api
  DATABASE = "build.db"

  def self.connection(&)
    check_db
    DB.open "sqlite3:./#{DATABASE}" do |db|
      yield db
    end
  end

  def self.add_job(task)
    connection do |db|
      db.exec "insert into jobs(id,checksum,repo,branch,source,arch,sha,username,password,force) values(?,?,?,?,?,?,?,?,?,?)",
        task.id, task.checksum.to_i64, task.repository, task.branch, task.source_file, task.arch, task.commit, task.username, task.password, task.force_compile?
    end
  end

  def self.update_status(id, state, msg)
    connection do |db|
      db.exec "update status set state = ?, message = ? where id = ?", state.value, msg, id
    end
  end

  def self.update_status(id, checksum, state, msg)
    connection do |db|
      db.exec %( insert into status(id, checksum,state,message) values (?,?,?,?)
                    on conflict(id) do update set state=excluded.state, message=excluded.message where id=excluded.id), id, checksum.to_i64, state.value, msg
    end
  end

  def self.attempts(checksum, status)
    connection do |db|
      db.scalar("select count(*) from status where checksum = ? and state = ?", checksum.to_i64, status.value).as(Int64)
    end
  end

  def self.get_status(id)
    connection do |db|
      TaskStatus.from_rs(db.query %(select s.state, s.id, s.message, s.updated_at, j.source, j.repo, j.branch, j.sha  from status s, jobs j where j.id = s.id and s.id = ?), id).first? rescue nil
    end
  end

  def self.job_exists?(csum)
    connection do |db|
      db.scalar("select count(*) from status where checksum = ? and state <= 1", csum.to_i64).as(Int64) > 0
    end
  end

  def self.get_last_result(csum)
    sql = "select s.state, s.id, s.message, s.updated_at, j.source, j.repo, j.branch, j.sha from status s, jobs j where j.id = s.id and s.checksum = ? order by updated_at desc limit 1"
    connection do |db|
      TaskStatus.from_rs(db.query(sql, csum.to_i64)).first
    end
  end

  def self.get_job_queue(state : State = State::Pending)
    sql = "select s.state, s.id, s.message, j.source, s.updated_at, j.repo, j.branch, j.sha from status s, jobs j where j.id = s.id and s.state = ? order by updated_at"
    connection do |db|
      TaskStatus.from_rs(db.query(sql, state.value))
    end
  end

  def self.get_incomplete_tasks
    sql = %(select j.id,j.repo,j.branch,j.source,j.arch,j.sha,j.username,j.password,j.force, s.state,s.message from jobs j, status s where j.id = s.id and s.state <= 1 order by j.created )
    connection do |db|
      Task.from_rs(db.query(sql))
    end
  end

  def self.check_db
    return if File.exists?(DATABASE)
    sqls = [
      "create table jobs (id text primary key, checksum integer, repo text, branch text, source text, arch text, sha text, username text, password text, force integer, created timestamp default CURRENT_TIMESTAMP)",
      "create table status(id text primary key, checksum integer, state integer, message text, updated_at timestamp default CURRENT_TIMESTAMP )",
    ]
    DB.open "sqlite3:./#{DATABASE}" do |db|
      sqls.each { |sql| db.exec(sql) }
    end
  end
end

PlaceOS::Api.check_db
