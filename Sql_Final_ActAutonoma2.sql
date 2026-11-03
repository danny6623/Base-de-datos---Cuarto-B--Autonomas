
DROP DATABASE IF EXISTS GestionMatriculas;
CREATE DATABASE GestionMatriculas CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE GestionMatriculas;

/* ---------- 1. TABLAS BASE ---------- */
CREATE TABLE Estudiantes (
    estudiante_id INT AUTO_INCREMENT PRIMARY KEY,
    cedula        CHAR(10)     NOT NULL UNIQUE,
    nombre        VARCHAR(100) NOT NULL,
    facultad      VARCHAR(100) NOT NULL
);

CREATE TABLE Asignaturas (
    asignatura_id     INT AUTO_INCREMENT PRIMARY KEY,
    nombre            VARCHAR(100) NOT NULL,
    docente           VARCHAR(100) NOT NULL,
    cupo_maximo       INT NOT NULL CHECK (cupo_maximo > 0),
    cupos_disponibles INT NOT NULL
);

CREATE TABLE Registros_Matricula (
    registro_id    INT AUTO_INCREMENT PRIMARY KEY,
    estudiante_id  INT NOT NULL,
    asignatura_id  INT NOT NULL,
    fecha_registro DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT UQ_Matricula UNIQUE (estudiante_id, asignatura_id),
    CONSTRAINT FK_Reg_Est FOREIGN KEY (estudiante_id) REFERENCES Estudiantes(estudiante_id),
    CONSTRAINT FK_Reg_Asig FOREIGN KEY (asignatura_id) REFERENCES Asignaturas(asignatura_id)
);

/* ---------- TABLAS NUEVAS ---------- */
CREATE TABLE Auditoria_Matriculas (
    auditoria_id INT AUTO_INCREMENT PRIMARY KEY,
    registro_id  INT NOT NULL,  -- sin FK: debe sobrevivir al borrado del registro
    accion       ENUM('MATRICULACIÓN','RETIRO') NOT NULL,
    usuario      VARCHAR(128) NOT NULL,
    fecha        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE Historial_Cupos (
    historial_id  INT AUTO_INCREMENT PRIMARY KEY,
    asignatura_id INT NOT NULL,
    cupo_anterior INT NOT NULL,
    cupo_nuevo    INT NOT NULL,
    fecha_cambio  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    usuario       VARCHAR(128) NOT NULL  -- valor agregado: quien hizo el cambio
);

/* ---------- 2. VISTAS ---------- */
CREATE VIEW Vista_OfertaAcademica AS
SELECT  a.asignatura_id     AS IdAsignatura,
        a.nombre            AS Materia,
        a.docente           AS Docente,
        a.cupo_maximo       AS CupoMaximo,
        a.cupos_disponibles AS CuposDisponibles,
        ROUND((a.cupo_maximo - a.cupos_disponibles) * 100.0 / a.cupo_maximo, 2) AS PorcentajeOcupacion
FROM Asignaturas a
WHERE a.cupos_disponibles > 0;

CREATE VIEW Vista_DetalleMatricula AS
SELECT  r.registro_id    AS IdRegistro,
        e.nombre         AS Estudiante,
        e.facultad       AS Facultad,
        a.nombre         AS Materia,
        r.fecha_registro AS FechaRegistro
FROM Registros_Matricula r
JOIN Estudiantes e ON e.estudiante_id = r.estudiante_id
JOIN Asignaturas a ON a.asignatura_id = r.asignatura_id;

CREATE VIEW Vista_EstudiantesSaturados AS
SELECT  e.estudiante_id AS IdEstudiante,
        e.nombre        AS Estudiante,
        e.facultad      AS Facultad,
        COUNT(*)        AS TotalMaterias
FROM Estudiantes e
JOIN Registros_Matricula r ON r.estudiante_id = e.estudiante_id
GROUP BY e.estudiante_id, e.nombre, e.facultad
HAVING COUNT(*) > 5;

DELIMITER $$

/* ---------- 3. FUNCIONES ---------- */
CREATE FUNCTION fn_CalcularCostoMatricula (p_estudiante_id INT)
RETURNS DECIMAL(10,2)
READS SQL DATA
BEGIN
    DECLARE v_materias INT;
    DECLARE v_costo DECIMAL(10,2) DEFAULT 15.00;
    SELECT COUNT(*) INTO v_materias FROM Registros_Matricula
    WHERE estudiante_id = p_estudiante_id;
    RETURN v_materias * v_costo;
END$$

CREATE FUNCTION fn_VerificarDisponibilidad (p_asignatura_id INT)
RETURNS TINYINT(1)
READS SQL DATA
BEGIN
    DECLARE v_cupos INT DEFAULT 0;
    SELECT cupos_disponibles INTO v_cupos FROM Asignaturas
    WHERE asignatura_id = p_asignatura_id;
    RETURN IF(IFNULL(v_cupos, 0) > 0, 1, 0);
END$$

/* MySQL no permite funciones que devuelvan tablas: la "funcion de tabla"
   se implementa como procedimiento que devuelve un conjunto de resultados */
CREATE PROCEDURE fn_ListaClase (IN p_asignatura_id INT)
BEGIN
    SELECT e.nombre AS Nombre, e.cedula AS Cedula
    FROM Registros_Matricula r
    JOIN Estudiantes e ON e.estudiante_id = r.estudiante_id
    WHERE r.asignatura_id = p_asignatura_id;
END$$

/* ---------- 4. PROCEDIMIENTOS ALMACENADOS ---------- */
CREATE PROCEDURE sp_InscribirAsignatura (IN p_estudiante_id INT, IN p_asignatura_id INT)
BEGIN
    DECLARE v_cupos INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET @origen = NULL;
        RESIGNAL;
    END;

    -- Validacion de parametros
    IF NOT EXISTS (SELECT 1 FROM Estudiantes WHERE estudiante_id = p_estudiante_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El estudiante no existe.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM Asignaturas WHERE asignatura_id = p_asignatura_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La asignatura no existe.';
    END IF;

    START TRANSACTION;
    SET @origen = 'SP';   -- marca: el cambio de cupo lo hace el sistema, no un administrador

    SELECT cupos_disponibles INTO v_cupos FROM Asignaturas
    WHERE asignatura_id = p_asignatura_id FOR UPDATE;   -- bloquea la fila: evita doble matricula simultanea

    IF v_cupos <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No hay cupos disponibles en la asignatura.';
    END IF;
    IF EXISTS (SELECT 1 FROM Registros_Matricula
               WHERE estudiante_id = p_estudiante_id AND asignatura_id = p_asignatura_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El estudiante ya esta matriculado en esta asignatura.';
    END IF;

    INSERT INTO Registros_Matricula (estudiante_id, asignatura_id)
    VALUES (p_estudiante_id, p_asignatura_id);

    UPDATE Asignaturas SET cupos_disponibles = cupos_disponibles - 1
    WHERE asignatura_id = p_asignatura_id;

    COMMIT;
    SET @origen = NULL;
    SELECT 'Matricula realizada correctamente.' AS Mensaje;
END$$

CREATE PROCEDURE sp_RetirarAsignatura (IN p_estudiante_id INT, IN p_asignatura_id INT)
BEGIN
    DECLARE v_registro_id INT DEFAULT NULL;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET @origen = NULL;
        RESIGNAL;
    END;

    SELECT registro_id INTO v_registro_id FROM Registros_Matricula
    WHERE estudiante_id = p_estudiante_id AND asignatura_id = p_asignatura_id;

    IF v_registro_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El estudiante no esta matriculado en esa asignatura.';
    END IF;

    START TRANSACTION;
    SET @origen = 'SP';

    DELETE FROM Registros_Matricula WHERE registro_id = v_registro_id;

    UPDATE Asignaturas SET cupos_disponibles = cupos_disponibles + 1
    WHERE asignatura_id = p_asignatura_id;

    INSERT INTO Auditoria_Matriculas (registro_id, accion, usuario)
    VALUES (v_registro_id, 'RETIRO', USER());

    COMMIT;
    SET @origen = NULL;
    SELECT 'Retiro realizado correctamente.' AS Mensaje;
END$$

CREATE PROCEDURE sp_ReporteCargaDocente ()
BEGIN
    SELECT  a.docente                       AS Docente,
            COUNT(DISTINCT a.asignatura_id) AS TotalMaterias,
            COUNT(r.registro_id)            AS TotalEstudiantes
    FROM Asignaturas a
    LEFT JOIN Registros_Matricula r ON r.asignatura_id = a.asignatura_id
    GROUP BY a.docente
    ORDER BY TotalEstudiantes DESC;
END$$

/* ---------- 5. TRIGGERS ---------- */
-- 5.1 Auditoria automatica de matriculas
CREATE TRIGGER tr_AuditoriaMatricula_Insert
AFTER INSERT ON Registros_Matricula
FOR EACH ROW
BEGIN
    INSERT INTO Auditoria_Matriculas (registro_id, accion, usuario, fecha)
    VALUES (NEW.registro_id, 'MATRICULACIÓN', USER(), NOW());
END$$

-- 5.2 Impide cupos negativos (MySQL no tiene INSTEAD OF: se usa BEFORE UPDATE)
CREATE TRIGGER tr_ValidarCupoNegativo
BEFORE UPDATE ON Asignaturas
FOR EACH ROW
BEGIN
    IF NEW.cupos_disponibles < 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Operacion bloqueada: el cupo de la asignatura no puede ser menor a cero.';
    END IF;
END$$

-- 5.3 Historial de cambios manuales de cupo
CREATE TRIGGER tr_LogCambioCupo
AFTER UPDATE ON Asignaturas
FOR EACH ROW
BEGIN
    -- Si el cambio viene de un SP del sistema, no es "manual": no se registra
    IF OLD.cupos_disponibles <> NEW.cupos_disponibles AND IFNULL(@origen, '') <> 'SP' THEN
        INSERT INTO Historial_Cupos (asignatura_id, cupo_anterior, cupo_nuevo, usuario)
        VALUES (OLD.asignatura_id, OLD.cupos_disponibles, NEW.cupos_disponibles, USER());
    END IF;
END$$

DELIMITER ;

/* ---------- 6. DATOS DE PRUEBA ---------- */
INSERT INTO Estudiantes (cedula, nombre, facultad) VALUES
('0601000001','Ana Torres','Ingeniería'),
('0601000002','Luis Mora','Ingeniería'),
('0601000003','Carla Vega','Ciencias de la Salud'),
('0601000004','Pedro Silva','Ciencias Políticas');

INSERT INTO Asignaturas (nombre, docente, cupo_maximo, cupos_disponibles) VALUES
('Bases de Datos',        'Ing. Paredes', 30, 30),
('Programación Avanzada', 'Ing. Paredes', 25, 25),
('Redes de Datos',        'Ing. Lopez',   25, 25),
('Sistemas Operativos',   'Ing. Lopez',   20, 20),
('Estadística',           'Dra. Ruiz',    20, 20),
('Cálculo',               'Dra. Ruiz',    20, 20),
('Ética Profesional',     'Mgs. Cruz',    15, 15),
('Materia Llena (prueba)','Mgs. Cruz',     1,  1);
