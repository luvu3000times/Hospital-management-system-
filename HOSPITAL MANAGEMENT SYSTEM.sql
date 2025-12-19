create database hospitaldb;
go

use hospitaldb;
go

create table department
(
    departmentid int identity(1,1) primary key,
    departmentname varchar(100) not null unique
);

create table doctors
(
    doctorid int identity(1,1) primary key,
    firstname varchar(100) not null,
    lastname varchar(100) not null,
    phoneno varchar(20),
    email varchar(50),
    departmentid int not null,
    specialization varchar(100),
    constraint fk_doctors_department foreign key (departmentid)
    references department(departmentid)
);

create table patients
(
    patientid int identity(1,1) primary key,
    firstname varchar(50) not null,
    lastname varchar(50) not null,
    gender char(1) check (gender in ('m','f','o')),
    phoneno varchar(20),
    email varchar(100),
    addressline1 varchar(200),
    city varchar(100),
    createdat datetime2 default sysdatetime()
);

create table rooms
(
    roomid int identity(1,1) primary key,
    roomno varchar(15) not null unique,
    roomtype varchar(50) not null,
    dailyrate decimal(10,2) not null,
    status varchar(20) not null default 'available',
    constraint chk_room_status check (status in ('available','occupied','maintenance'))
);

create table appointment
(
    appointmentid int identity(1,1) primary key,
    patientid int not null,
    doctorid int not null,
    appointmentdate datetime2 not null,
    status varchar(20) not null default 'scheduled',
    reason varchar(200),
    constraint fk_appointment_patient foreign key (patientid)
    references patients(patientid),
    constraint fk_appointment_doctor foreign key (doctorid)
    references doctors(doctorid),
    constraint chk_appointment_status check (status in ('scheduled','completed','cancelled'))
);

create table admission
(
    admissionid int identity(1,1) primary key,
    patientid int not null,
    roomid int not null,
    doctorid int not null,
    admitdate datetime2 not null default sysdatetime(),
    dischargedate datetime2 null,
    diagnosis varchar(300),
    status varchar(20) not null default 'admitted',
    constraint fk_admission_patient foreign key (patientid)
    references patients(patientid),
    constraint fk_admission_room foreign key (roomid)
    references rooms(roomid),
    constraint fk_admission_doctor foreign key (doctorid)
    references doctors(doctorid),
    constraint chk_admission_status check (status in ('admitted','discharged'))
);

create table treatments
(
    treatmentid int identity(1,1) primary key,
    patientid int not null,
    doctorid int not null,
    treatmentdate datetime2 default sysdatetime(),
    diagnosis varchar(300),
    notes varchar(200),
    admissionid int null,
    constraint fk_treatment_patient foreign key (patientid)
    references patients(patientid),
    constraint fk_treatment_doctor foreign key (doctorid)
    references doctors(doctorid),
    constraint fk_treatment_admission foreign key (admissionid)
    references admission(admissionid)
);

create table bills
(
    billid int identity(1,1) primary key,
    patientid int not null,
    admissionid int not null,
    billdate datetime2 default sysdatetime(),
    amount decimal(10,2) not null,
    billtype varchar(20) not null,
    paymentstatus varchar(20) default 'unpaid',
    constraint fk_bill_patient foreign key (patientid)
    references patients(patientid),
    constraint fk_bill_admission foreign key (admissionid)
    references admission(admissionid),
    constraint chk_bill_type check (billtype in ('ipd','opd')),
    constraint chk_payment_status check (paymentstatus in ('paid','unpaid'))
);

create unique index ux_doctor_appointment
on appointment (doctorid, appointmentdate)
where status = 'scheduled';

create or alter procedure usp_scheduleappointment
@patientid int,
@doctorid int,
@appointmentdate datetime2,
@reason varchar(200)
as
begin
    set nocount on;

    if not exists (select 1 from patients where patientid = @patientid)
    begin
        raiserror ('invalid patient id',16,1);
        return;
    end

    if not exists (select 1 from doctors where doctorid = @doctorid)
    begin
        raiserror ('invalid doctor id',16,1);
        return;
    end

    if exists (
        select 1 from appointment
        where doctorid = @doctorid
        and appointmentdate = @appointmentdate
        and status = 'scheduled'
    )
    begin
        raiserror ('appointment already exists',16,1);
        return;
    end

    insert into appointment (patientid, doctorid, appointmentdate, reason)
    values (@patientid, @doctorid, @appointmentdate, @reason);

    select scope_identity() as appointmentid;
end;
go

create or alter procedure usp_admitpatient
@patientid int,
@roomid int,
@doctorid int,
@diagnosis varchar(300)
as
begin
    set nocount on;

    if not exists (select 1 from patients where patientid = @patientid)
    begin
        raiserror ('invalid patient id',16,1);
        return;
    end

    if not exists (select 1 from doctors where doctorid = @doctorid)
    begin
        raiserror ('invalid doctor id',16,1);
        return;
    end

    if not exists (select 1 from rooms where roomid = @roomid and status = 'available')
    begin
        raiserror ('room not available',16,1);
        return;
    end

    begin transaction;

        insert into admission (patientid, roomid, doctorid, diagnosis)
        values (@patientid, @roomid, @doctorid, @diagnosis);

        update rooms
        set status = 'occupied'
        where roomid = @roomid;

        select scope_identity() as admissionid;

    commit transaction;
end;
go

create or alter procedure usp_dischargepatient
@admissionid int
as
begin
    set nocount on;

    declare @patientid int,
            @roomid int,
            @admitdate datetime2,
            @dischargedate datetime2,
            @dailyrate decimal(10,2),
            @days int,
            @amount decimal(10,2);

    select 
        @patientid = patientid,
        @roomid = roomid,
        @admitdate = admitdate
    from admission
    where admissionid = @admissionid
    and status = 'admitted';

    if @patientid is null
    begin
        raiserror ('invalid admission id',16,1);
        return;
    end

    set @dischargedate = sysdatetime();

    select @dailyrate = dailyrate from rooms where roomid = @roomid;

    set @days = datediff(day, @admitdate, @dischargedate);
    if @days < 1 set @days = 1;

    set @amount = @days * @dailyrate;

    begin transaction;

        update admission
        set dischargedate = @dischargedate,
            status = 'discharged'
        where admissionid = @admissionid;

        update rooms
        set status = 'available'
        where roomid = @roomid;

        insert into bills (patientid, admissionid, amount, billtype)
        values (@patientid, @admissionid, @amount, 'ipd');

    commit transaction;
end;
go

create view v_patient_visit_summary
as
select
    p.patientid,
    p.firstname,
    p.lastname,
    count(distinct a.appointmentid) as total_appointments,
    count(distinct ad.admissionid) as total_admissions
from patients p
left join appointment a on p.patientid = a.patientid
left join admission ad on p.patientid = ad.patientid
group by p.patientid, p.firstname, p.lastname;
go

create or alter view v_doctor_schedule
as
select
    d.doctorid,
    d.firstname as doctorfirstname,
    d.lastname as doctorlastname,
    dept.departmentname,
    a.appointmentid,
    a.appointmentdate,
    a.status as appointmentstatus,
    p.firstname as patientfirstname,
    p.lastname as patientlastname
from doctors d
join department dept
    on d.departmentid = dept.departmentid
left join appointment a
    on d.doctorid = a.doctorid
left join patients p
    on a.patientid = p.patientid;
go

create or alter view v_patient_total_ipd
as
select
    p.patientid,
    p.firstname,
    p.lastname,
    count(a.admissionid) as totalipd
from patients p
left join admission a
    on p.patientid = a.patientid
group by p.patientid, p.firstname, p.lastname;
go



--- to insert sample datas

insert into department (departmentname) values
('cardiology'),
('neurology'),
('orthopedics'),
('pediatrics'),
('general medicine');

insert into doctors (firstname, lastname, phoneno, email, departmentid, specialization) values
('john','doe','9876543210','john@hospital.com',1,'heart specialist'),
('priya','sharma','9876543211','priya@hospital.com',2,'brain specialist'),
('amit','kumar','9876543212','amit@hospital.com',3,'bone specialist'),
('sara','thomas','9876543213','sara@hospital.com',4,'child specialist'),
('rahul','verma','9876543214','rahul@hospital.com',5,'general physician');

insert into patients (firstname, lastname, gender, phoneno, email, addressline1, city) values
('ravi','kumar','m','9000011111','ravi@mail.com','street a','chennai'),
('sneha','rao','f','9000022222','sneha@mail.com','street b','bangalore'),
('karan','singh','m','9000033333','karan@mail.com','street c','delhi'),
('meera','nair','f','9000044444','meera@mail.com','street d','kochi'),
('arun','joseph','m','9000055555','arun@mail.com','street e','chennai'),
('lakshmi','menon','f','9000066666','lakshmi@mail.com','street f','hyderabad'),
('vikram','shetty','m','9000077777','vikram@mail.com','street g','mumbai'),
('divya','shah','f','9000088888','divya@mail.com','street h','ahmedabad'),
('suresh','patel','m','9000099999','suresh@mail.com','street i','surat'),
('anjali','jain','f','9000010000','anjali@mail.com','street j','pune');

insert into rooms (roomno, roomtype, dailyrate, status) values
('r101','general',1500.00,'available'),
('r102','icu',5000.00,'available'),
('r103','semi-private',3000.00,'available'),
('r104','private',4000.00,'available'),
('r105','general',1500.00,'available');

insert into appointment (patientid, doctorid, appointmentdate, reason) values
(1,1,'2025-01-10 10:00','chest pain'),
(2,2,'2025-01-11 11:00','headache'),
(3,3,'2025-01-12 09:30','back pain'),
(4,4,'2025-01-13 12:00','fever'),
(5,5,'2025-01-14 14:00','general checkup');

insert into admission (patientid, roomid, doctorid, diagnosis) values
(6,1,1,'heart issue'),
(7,2,2,'neuro issue'),
(8,3,3,'leg fracture'),
(9,4,4,'viral infection');

insert into treatments (patientid, doctorid, diagnosis, notes, admissionid) values
(6,1,'heart check','ecg performed',1),
(7,2,'brain scan','mri done',2),
(8,3,'bone treatment','x-ray taken',3),
(9,4,'infection treatment','medication ongoing',4);


--stored procedure

	--schedule appointment
		
	exec usp_scheduleappointment
    @patientid = 1,
    @doctorid = 3,
    @appointmentdate = '2025-01-22 09:00',
    @reason = 'back pain';

	exec usp_scheduleappointment
    @patientid = 2,
    @doctorid = 4,
    @appointmentdate = '2025-01-23 11:15',
    @reason = 'child fever';

	--admit patient
	exec usp_admitpatient
    @patientid = 6,
    @roomid = 2,
    @doctorid = 1,
    @diagnosis = 'heart problem';

	exec usp_admitpatient
    @patientid = 7,
    @roomid = 3,
    @doctorid = 2,
    @diagnosis = 'neuro observation';


	--discharge patient (billing generated)

	exec usp_dischargepatient
    @admissionid = 1;


	--check generated bill

	select *
	from bills
	where admissionid = 1;


	--view bill with patient details

select
    b.billid,
    p.firstname + ' ' + p.lastname as patientname,
    b.amount,
    b.billtype,
    b.paymentstatus,
    b.billdate
from bills b
join patients p on b.patientid = p.patientid
where b.admissionid = 1;


	--mark bill as paid

		update bills
		set paymentstatus = 'paid'
		where billid = 1;

	--verify payment update

		select billid, paymentstatus
		from bills
		where billid = 1;

--views/monitor

--patient vist summary

select * from v_patient_visit_summary;

select * 
from v_patient_visit_summary
where total_admissions > 0;


--doctor schedule view

select * from v_doctor_schedule;


select *
from v_doctor_schedule
where doctorid = 1;


select *
from v_doctor_schedule
where departmentname = 'cardiology';


select *
from v_doctor_schedule
where appointmentstatus = 'scheduled';

select *
from v_doctor_schedule
order by appointmentdate;

select
    doctorfirstname,
    doctorlastname,
    count(appointmentid) as totalappointments
from v_doctor_schedule
group by doctorfirstname, doctorlastname;

--total ipd

select * from v_patient_total_ipd;

select *
from v_patient_total_ipd
where totalipd > 0;

select *
from v_patient_total_ipd
order by totalipd desc;

--currently admitted patients only

select
    p.patientid,
    p.firstname,
    p.lastname,
    a.admitdate,
    a.status
from patients p
join admission a
    on p.patientid = a.patientid
where a.status = 'admitted';

--discharged patient only

select
    p.patientid,
    p.firstname,
    p.lastname,
    a.dischargedate
from patients p
join admission a
    on p.patientid = a.patientid
where a.status = 'discharged';



